// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Asset, SettleNativeAtomicProviderStorageData, SettleNativeAtomicProviderStorageV1} from "./SettleNativeAtomicProviderStorageV1.sol";
interface IDecimals {
    function decimals() external view returns (uint8);
}
interface IPriceFeed is IDecimals {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
interface IMorphoVaultV2 {
    function liquidityAdapter() external view returns (address);
    function liquidityData() external view returns (bytes memory);
    function isAdapter(address account) external view returns (bool);
}
interface IMorphoMarketAdapter {
    function expectedSupplyAssets(bytes32 marketId) external view returns (uint256);
    function morpho() external view returns (address);
}
interface IMorphoAdapterFactory {
    function morphoMarketV1AdapterV2(address parentVault) external view returns (address);
}
interface IMorpho {
    function market(bytes32 marketId)
        external
        view
        returns (uint128 totalSupplyAssets, uint128 totalSupplyShares, uint128 totalBorrowAssets, uint128 totalBorrowShares, uint128 lastUpdate, uint128 fee);
}
contract SettleNativeAtomicProvider is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    uint256 private constant BPS = 10_000;
    uint256 private constant MAX_DECIMALS = 18;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IERC4626 public immutable vault;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IERC20 public immutable stable;
    event Sold(address indexed seller, address indexed rwa, uint256 rwaReceived, uint256 stablePaid);
    event AssetSet(address indexed rwa, address indexed priceFeed, uint16 discountBps, uint32 maxAge, uint256 maxExposure);
    event VaultFunded(uint256 stableAmount);
    event ExposureReduced(address indexed rwa, uint256 rwaRedeemed);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(IERC4626 _vault) {
        vault = _vault;
        stable = IERC20(_vault.asset());
        _disableInitializers();
    }
    function initialize(address initialOwner) public initializer {
        __Ownable_init(initialOwner);
    }
    modifier whenOpen() {
        require(!_getStorage().paused, "PAUSED");
        require(stablePriceInRange(), "DEPEG");
        _;
    }
    function assets(address rwa) external view returns (Asset memory) {
        return _getStorage().assets[rwa];
    }
    function paused() external view returns (bool) {
        return _getStorage().paused;
    }
    function pauser() external view returns (address) {
        return _getStorage().pauser;
    }
    function morphoAdapterFactory() external view returns (address) {
        return _getStorage().morphoAdapterFactory;
    }
    function stableFeed() external view returns (address feed, uint16 maxDeviationBps, uint32 maxAge) {
        SettleNativeAtomicProviderStorageData storage $ = _getStorage();
        return ($.stableFeed, $.stableMaxDeviationBps, $.stableMaxAge);
    }
    function stablePriceInRange() public view returns (bool) {
        SettleNativeAtomicProviderStorageData storage $ = _getStorage();
        if ($.stableFeed == address(0)) return true;
        (bool hasPrice, uint256 price) = _readPrice($.stableFeed, $.stableMaxAge);
        if (!hasPrice) return false;
        (bool hasScale, uint256 par) = _readScale($.stableFeed);
        if (!hasScale) return false;
        uint256 maxDeviation = (par * $.stableMaxDeviationBps) / BPS;
        return price + maxDeviation >= par && price <= par + maxDeviation;
    }
    function quote(address rwa, uint256 amountIn) external view whenOpen returns (uint256 amountOut) {
        Asset storage a = _getStorage().assets[rwa];
        require(a.priceFeed != address(0), "NOT_ACCEPTED");
        return _quote(rwa, a, amountIn);
    }
    function maxAmountIn(address rwa) external view returns (uint256) {
        SettleNativeAtomicProviderStorageData storage $ = _getStorage();
        if ($.paused || !stablePriceInRange()) return 0;
        Asset storage a = $.assets[rwa];
        if (a.priceFeed == address(0)) return 0;
        (uint256 numerator, uint256 denominator) = _exchangeRate(rwa, a);
        if (numerator == 0) return 0;
        uint256 roomUnderCap = a.maxExposure > a.exposure ? a.maxExposure - a.exposure : 0;
        uint256 roomInVault = (vaultLiquidity() * denominator) / numerator;
        return roomUnderCap < roomInVault ? roomUnderCap : roomInVault;
    }
    function vaultLiquidity() public view returns (uint256) {
        uint256 value = vault.previewRedeem(vault.balanceOf(address(this)));
        uint256 liquid;
        if (_getStorage().morphoAdapterFactory == address(0)) {
            try vault.maxWithdraw(address(this)) returns (uint256 available) {
                liquid = available;
            } catch {}
        } else {
            liquid = stable.balanceOf(address(vault));
            try this.morphoMarketLiquidity() returns (uint256 fromMarket) {
                liquid += fromMarket;
            } catch {}
        }
        return value < liquid ? value : liquid;
    }
    function morphoMarketLiquidity() public view returns (uint256) {
        address factory = _getStorage().morphoAdapterFactory;
        if (factory == address(0)) return 0;
        IMorphoVaultV2 morphoVault = IMorphoVaultV2(address(vault));
        address adapter = morphoVault.liquidityAdapter();
        if (adapter == address(0)) return 0;
        if (adapter != IMorphoAdapterFactory(factory).morphoMarketV1AdapterV2(address(vault))) return 0;
        if (!morphoVault.isAdapter(adapter)) return 0;
        bytes32 marketId = keccak256(morphoVault.liquidityData());
        (uint128 supplyAssets,, uint128 borrowAssets,,,) = IMorpho(IMorphoMarketAdapter(adapter).morpho()).market(marketId);
        uint256 freeInMarket = supplyAssets > borrowAssets ? supplyAssets - borrowAssets : 0;
        uint256 ourPosition = IMorphoMarketAdapter(adapter).expectedSupplyAssets(marketId);
        return ourPosition < freeInMarket ? ourPosition : freeInMarket;
    }
    function sell(address rwa, uint256 amountIn, uint256 minOut) external nonReentrant whenOpen returns (uint256 amountOut) {
        Asset storage a = _getStorage().assets[rwa];
        require(a.priceFeed != address(0), "NOT_ACCEPTED");
        IERC20 token = IERC20(rwa);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 received = token.balanceOf(address(this)) - before;
        amountOut = _quote(rwa, a, received);
        require(amountOut >= minOut, "MIN_OUT");
        require(amountOut > 0, "ZERO_OUT");
        a.exposure += received;
        require(a.exposure <= a.maxExposure, "MAX_EXPOSURE");
        vault.withdraw(amountOut, msg.sender, address(this));
        emit Sold(msg.sender, rwa, received, amountOut);
    }
    function setAsset(address rwa, address priceFeed, uint16 discountBps, uint32 maxAge, uint256 maxExposure) external onlyOwner {
        require(priceFeed != address(0), "ZERO_FEED");
        require(maxAge > 0, "ZERO_MAX_AGE");
        _setAsset(rwa, priceFeed, discountBps, maxAge, maxExposure);
    }
    function setDiscount(address rwa, uint16 discountBps) external onlyOwner {
        Asset storage a = _listedAsset(rwa);
        _setAsset(rwa, a.priceFeed, discountBps, a.maxAge, a.maxExposure);
    }
    function setMaxAge(address rwa, uint32 maxAge) external onlyOwner {
        require(maxAge > 0, "ZERO_MAX_AGE");
        Asset storage a = _listedAsset(rwa);
        _setAsset(rwa, a.priceFeed, a.discountBps, maxAge, a.maxExposure);
    }
    function setMaxExposure(address rwa, uint256 maxExposure) external onlyOwner {
        Asset storage a = _listedAsset(rwa);
        _setAsset(rwa, a.priceFeed, a.discountBps, a.maxAge, maxExposure);
    }
    function removeAsset(address rwa) external onlyOwner {
        Asset storage a = _listedAsset(rwa);
        _setAsset(rwa, address(0), a.discountBps, a.maxAge, a.maxExposure);
    }
    function setStableFeed(address feed, uint16 maxDeviationBps, uint32 maxAge) external onlyOwner {
        if (feed == address(0)) {
            require(maxDeviationBps == 0 && maxAge == 0, "PARAMS_WITH_ZERO_FEED");
        } else {
            require(maxDeviationBps > 0 && maxDeviationBps < BPS, "BAD_DEVIATION");
            require(maxAge > 0, "ZERO_MAX_AGE");
            _requireUsableFeed(feed, maxAge);
            (, uint256 par) = _readScale(feed);
            require((par * maxDeviationBps) / BPS > 0, "BAD_DEVIATION");
        }
        SettleNativeAtomicProviderStorageData storage $ = _getStorage();
        $.stableFeed = feed;
        $.stableMaxDeviationBps = maxDeviationBps;
        $.stableMaxAge = maxAge;
    }
    function setMorphoAdapterFactory(address factory) external onlyOwner {
        if (factory != address(0)) {
            try IMorphoVaultV2(address(vault)).liquidityAdapter() returns (address) {}
            catch {
                revert("NOT_MORPHO_VAULT_V2");
            }
            require(IMorphoAdapterFactory(factory).morphoMarketV1AdapterV2(address(vault)) != address(0), "NO_ADAPTER");
        }
        _getStorage().morphoAdapterFactory = factory;
    }
    function setPauser(address account) external onlyOwner {
        _getStorage().pauser = account;
    }
    function pause() external {
        SettleNativeAtomicProviderStorageData storage $ = _getStorage();
        require(msg.sender == $.pauser || msg.sender == owner(), "NOT_PAUSER");
        $.paused = true;
    }
    function unpause() external onlyOwner {
        _getStorage().paused = false;
    }
    function fundVault(uint256 stableAmount) external onlyOwner {
        _fundVault(stableAmount);
    }
    function reduceExposure(address rwa, uint256 rwaRedeemed) external onlyOwner {
        _reduceExposure(rwa, rwaRedeemed);
    }
    function bookRedemption(address rwa, uint256 rwaRedeemed, uint256 stableAmount) external onlyOwner {
        _reduceExposure(rwa, rwaRedeemed);
        _fundVault(stableAmount);
    }
    function withdrawERC20(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }
    function renounceOwnership() public pure override {
        revert("NO_RENOUNCE");
    }
    function _getStorage() internal pure returns (SettleNativeAtomicProviderStorageData storage) {
        return SettleNativeAtomicProviderStorageV1.load();
    }
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        SettleNativeAtomicProvider newImpl = SettleNativeAtomicProvider(newImplementation);
        require(newImpl.stable() == stable && newImpl.vault().asset() == address(stable), "ASSET_MISMATCH");
    }
    function _listedAsset(address rwa) private view returns (Asset storage a) {
        a = _getStorage().assets[rwa];
        require(a.priceFeed != address(0), "NOT_ACCEPTED");
    }
    function _setAsset(address rwa, address priceFeed, uint16 discountBps, uint32 maxAge, uint256 maxExposure) private {
        require(discountBps < BPS, "BAD_DISCOUNT");
        Asset storage a = _getStorage().assets[rwa];
        a.priceFeed = priceFeed;
        a.discountBps = discountBps;
        a.maxAge = maxAge;
        a.maxExposure = maxExposure;
        emit AssetSet(rwa, priceFeed, discountBps, maxAge, maxExposure);
    }
    function _fundVault(uint256 stableAmount) private {
        uint256 held = stable.balanceOf(address(this));
        if (held < stableAmount) stable.safeTransferFrom(msg.sender, address(this), stableAmount - held);
        stable.forceApprove(address(vault), stableAmount);
        vault.deposit(stableAmount, address(this));
        emit VaultFunded(stableAmount);
    }
    function _reduceExposure(address rwa, uint256 rwaRedeemed) private {
        Asset storage a = _getStorage().assets[rwa];
        require(a.exposure >= rwaRedeemed, "EXCEEDS_EXPOSURE");
        a.exposure -= rwaRedeemed;
        emit ExposureReduced(rwa, rwaRedeemed);
    }
    function _quote(address rwa, Asset storage a, uint256 amountIn) private view returns (uint256) {
        (uint256 numerator, uint256 denominator) = _exchangeRate(rwa, a);
        require(numerator > 0, "BAD_PRICE");
        return (amountIn * numerator) / denominator;
    }
    function _exchangeRate(address rwa, Asset storage a) private view returns (uint256 numerator, uint256 denominator) {
        (bool hasPrice, uint256 price) = _readPrice(a.priceFeed, a.maxAge);
        if (!hasPrice) return (0, 0);
        (bool hasFeedScale, uint256 feedScale) = _readScale(a.priceFeed);
        (bool hasStableScale, uint256 stableScale) = _readScale(address(stable));
        (bool hasRwaScale, uint256 rwaScale) = _readScale(rwa);
        if (!hasFeedScale || !hasStableScale || !hasRwaScale) return (0, 0);
        numerator = price * stableScale * (BPS - a.discountBps);
        denominator = feedScale * rwaScale * BPS;
    }
    function _requireUsableFeed(address feed, uint32 maxAge) private view {
        (bool hasPrice,) = _readPrice(feed, maxAge);
        (bool hasScale,) = _readScale(feed);
        require(hasPrice && hasScale, "FEED_UNREADABLE");
    }
    function _readPrice(address feed, uint32 maxAge) private view returns (bool ok, uint256 price) {
        (bool called, bytes memory data) = feed.staticcall(abi.encodeCall(IPriceFeed.latestRoundData, ()));
        if (!called || data.length < 160) return (false, 0);
        (, int256 answer,, uint256 updatedAt,) = abi.decode(data, (uint256, int256, uint256, uint256, uint256));
        if (answer <= 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) return (false, 0);
        return (true, uint256(answer));
    }
    function _readScale(address token) private view returns (bool ok, uint256 scale) {
        (bool called, bytes memory data) = token.staticcall(abi.encodeCall(IDecimals.decimals, ()));
        if (!called || data.length < 32) return (false, 0);
        uint256 decimals = abi.decode(data, (uint256));
        if (decimals > MAX_DECIMALS) return (false, 0);
        return (true, 10 ** decimals);
    }
}
