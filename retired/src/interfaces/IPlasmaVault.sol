// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

/// @notice FuseAction is a struct that represents a single action that can be executed by an Alpha
struct FuseAction {
    /// @notice fuse is an address of the Fuse contract
    address fuse;
    /// @notice data is a bytes data that is passed to the Fuse contract
    bytes data;
}

/// @title Plasma Vault interface with business methods
interface IPlasmaVault {
    /// @notice Returns the total assets in the market with the given marketId
    /// @param marketId_ The marketId of the market
    /// @return The total assets in the market represented in underlying token decimals
    function totalAssetsInMarket(uint256 marketId_) external view returns (uint256);

    /**
     * @notice Updates the balances of the specified markets.
     * @param marketIds_ The array of market IDs to update balances for.
     * @return The total assets in the Plasma Vault after updating the market balances.
     * @dev If the `marketIds_` array is empty, it returns the total assets without updating any market balances.
     *      This function first records the total assets before updating the market balances, then updates the balances,
     *      adds the performance fee based on the assets before the update, and finally returns the new total assets.
     */
    function updateMarketsBalances(uint256[] calldata marketIds_) external returns (uint256);

    /// @notice Gets unrealized management fee
    /// @return The unrealized management fee represented in underlying token decimals
    function getUnrealizedManagementFee() external view returns (uint256);

    /// @notice Execute fuse actions on the Plasma Vault via Fuses, by Alpha to perform actions which improve the performance earnings of the Plasma Vault
    /// @param calls_ The array of FuseActions to execute
    /// @dev Method is granted only to the Alpha
    function execute(FuseAction[] calldata calls_) external;

    /// @notice Claim rewards from the Plasma Vault via Rewards Fuses to claim rewards from connected protocols with the Plasma Vault
    /// @param calls_ The array of FuseActions to claim rewards
    /// @dev Method is granted only to the RewardsManager
    function claimRewards(FuseAction[] calldata calls_) external;

    /// @notice Deposit assets to the Plasma Vault with permit function
    /// @param assets_ The amount of underlying assets to deposit
    /// @param receiver_ The receiver of the assets
    /// @param deadline_ The deadline for the permit function
    /// @param v_ The v value of the signature
    /// @param r_ The r value of the signature
    /// @param s_ The s value of the signature
    /// @return The amount of shares minted
    function depositWithPermit(
        uint256 assets_,
        address receiver_,
        uint256 deadline_,
        uint8 v_,
        bytes32 r_,
        bytes32 s_
    ) external returns (uint256);

    function redeemFromRequest(uint256 shares_, address receiver_, address owner_)
        external
        returns (uint256);

    function deposit(uint256 assets_, address receiver_) external returns (uint256);

    function withdraw(uint256 assets_, address receiver_, address owner_)
        external
        returns (uint256 withdrawnShares);

    // ERC4626 standard view functions
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function maxDeposit(address receiver) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);

    // ERC20 functions needed
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);

    // ERC4626 redeem function
    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);
}
