# SNAP: known issues

Known behavior of the SNAP contracts in `../snap/` (`SettleNativeAtomicProvider`, `RedeemingSnap`,
`SnapMidas`, `SnapOpenEden`), deployed on Ethereum mainnet:

- SNAP Midas: `0xdEEF55CD91aDb852fC6F7eb50a2411696Fd292Fe`
- SNAP OpenEden: `0x4e8e43608e0a07BC8335f768a02571314F76a734`

Each item below is known and accepted, with the reason. A report of one of them is not a new
finding. Findings marked Acknowledged in the audit reports in this folder are known too.

## REDS-1: Sanctions screening covers the caller, not the token's previous owner

**Issue.** `sell` checks `msg.sender` and, when it differs, `tx.origin` against the sanctions list.
A listed holder can approve a contract, or move the tokens to another address, and have an
unlisted account sell them. SNAP pays the account that sold.

**Why it is accepted.** No check of the seller stops a listed holder who first transfers the token
to an unlisted address, so screening the token's source would not close this either. SNAP's
screening is an extra layer: it stops a listed account that sells itself or through its own
contract. Who may hold the tokens is the issuer's control: OpenEden moves TBILL only between
addresses it has KYC'd, and Midas can blacklist addresses for its mTokens.

## REDS-2: A change of a token's decimals loosens `maxPrice`

**Issue.** `maxPrice` caps the stable paid per 1e18 base units of the RWA, computed with the live
`decimals()` of the RWA, the feed and the stable. If an RWA later reported more decimals while its
feed still priced one whole token, the cap per whole token would loosen by that factor.

**Why it is accepted.** It needs the issuer to change the decimals of a live token, which changes
the value of every holder's balance. The payout itself still follows the feed's price at the live
decimals: the cap matters only if the price is wrong at the same time. The owner can pause SNAP or
remove the asset when an issuer announces such a change.

## REDS-3: `sellReceived` does not screen the filler

**Issue.** `sellReceived` checks only that the caller is a filler, not the sanctions list. A filler
listed later could still sell through it.

**Why it is accepted.** Fillers are contracts RedStone operates for its RFQ settlement, enabled by
the owner, and they screen the seller themselves. No filler is enabled on mainnet. The owner
disables one with `setFiller(filler, false)`.

## REDS-4: A booking deposits all the stable SNAP holds

**Issue.** `bookMidasRedemption` and `bookOpenEdenRedemption` deposit SNAP's whole stable balance
into the vault, not the proceeds of one request. If several requests were paid before a booking,
the first booking's event carries their sum and the later ones carry zero.

**Why it is accepted.** All the stable reaches the vault, and each booking lowers exposure by its
own request's amount. The event's amount is what was deposited, not one request's proceeds. Midas
pays a request in the same transaction that marks it Processed, so a Processed request is a paid
one.

## REDS-5: Someone else's OpenEden request naming SNAP as the receiver delays booking

**Issue.** OpenEden reports the shares queued per receiver, not per request. A KYC'd TBILL holder
can file a redemption with SNAP as the receiver. While it is queued, `bookOpenEdenRedemption`
counts it as SNAP's own: SNAP's paid shares stay in exposure (SNAP buys less), or the booking
reverts with `NOT_PROCESSED`.

**Why it is accepted.** The holder locks their own TBILL to do it. When OpenEden pays the request,
the stable goes to SNAP; when it cancels it, the shares go back to the holder. Once the request
leaves the queue, the next booking catches up. Nothing is lost, and the owner can also take the
amount off exposure by hand (`reduceExposure`, then `lowerQueued`).

## REDS-6: Two SNAPs on one vault count the same liquidity

**Issue.** Both SNAPs hold shares of the same Morpho Vault V2
(`0x8c106EEDAd96553e64287A5A6839c3Cc78afA3D0`). Each one's `maxAmountIn` counts the vault's
withdrawable liquidity on its own, so their sum can exceed what the vault can pay out at once.

**Why it is accepted.** A sale the vault cannot pay reverts in `vault.withdraw`, and the seller
keeps their tokens. Each SNAP pays only from its own shares. The liquidity free in the vault's
Morpho market is orders of magnitude larger than both SNAPs' shares together, so the double count
matters only when that market is almost fully borrowed, and then neither SNAP could pay anyway.
