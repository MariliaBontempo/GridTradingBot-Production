// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAutomationCompatibleInterface
/// @notice Interface for Chainlink Automation (formerly Keepers)
/// @dev Contracts must implement this interface to be compatible with Chainlink Automation
interface IAutomationCompatibleInterface {
    /// @notice Method that is simulated by the keepers to see if any work actually needs to be performed
    /// @dev To ensure that it is never called, you may want to add the cannotExecute modifier from KeeperBase to your implementation
    /// @param checkData specified in the upkeep registration (passed by the keeper)
    /// @return upkeepNeeded boolean to indicate whether the keeper should call performUpkeep or not
    /// @return performData bytes that the keeper should call performUpkeep with, if upkeep is needed
    function checkUpkeep(bytes calldata checkData) external returns (bool upkeepNeeded, bytes memory performData);

    /// @notice Method that is actually executed by the keepers, via the registry
    /// @dev The input to this method should not be trusted, and the caller of the method should not even be restricted to any single registry.
    /// Anyone should be able to call it, and the function should do proper validation
    /// @param performData The data which was passed back from the checkData simulation
    function performUpkeep(bytes calldata performData) external;
}
