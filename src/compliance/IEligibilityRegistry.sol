// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/**
 * @title IEligibilityRegistry
 * @notice The one question a compliance gate answers: may this address trade?
 *
 * @dev An offering may name a registry; when it does, {OTCTrading.createOrder} refuses a maker the
 * registry will not vouch for, and {OTCTrading.fillOrder} refuses unless it vouches for BOTH sides
 * at the moment of settlement — so someone whose verification lapses while their order rests can no
 * longer trade on it. The trading contract deliberately knows nothing about *why*: KYC status,
 * jurisdiction, a manually kept list — that is the registry's business.
 *
 * Anything can stand behind this interface: `WhitelistRegistry` for an operator-kept list, or
 * `ERC3643EligibilityAdapter` to defer to a permissioned token's own identity registry.
 *
 * @notice Exiting is never gated. Cancelling an order and withdrawing accrued ETH stay open to a
 * de-listed address, because a compliance gate must stop new trading, not confiscate.
 */
interface IEligibilityRegistry {
    /// @notice Whether `account` may currently trade.
    function isEligible(address account) external view returns (bool);
}
