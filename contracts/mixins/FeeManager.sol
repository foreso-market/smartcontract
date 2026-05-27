// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

abstract contract FeeManager {

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    uint256 public takerFeeRate;

    uint256 public makerFeeRate;

    address public feeRecipient;

    uint256 public constant MAX_FEE_RATE = 200; // 2%

    uint256 private constant BPS_DIVISOR = 10000;

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    event TakerFeeRateUpdated(
        uint256 oldRate,
        uint256 newRate,
        address indexed updatedBy
    );

    event MakerFeeRateUpdated(
        uint256 oldRate,
        uint256 newRate,
        address indexed updatedBy
    );

    event FeeRecipientUpdated(
        address indexed oldRecipient,
        address indexed newRecipient,
        address indexed updatedBy
    );

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    error FeeRateTooHigh();

    error InvalidFeeRecipient();

    /*//////////////////////////////////////////////////////////////

    //////////////////////////////////////////////////////////////*/

    function _initializeFeeManager(
        uint256 initialTakerFeeRate,
        uint256 initialMakerFeeRate,
        address initialFeeRecipient
    ) internal {
        if (initialTakerFeeRate > MAX_FEE_RATE) revert FeeRateTooHigh();
        if (initialMakerFeeRate > MAX_FEE_RATE) revert FeeRateTooHigh();
        if (initialFeeRecipient == address(0)) revert InvalidFeeRecipient();

        takerFeeRate = initialTakerFeeRate;
        makerFeeRate = initialMakerFeeRate;
        feeRecipient = initialFeeRecipient;
    }

    function _calculateTakerFee(uint256 amount) internal view returns (uint256) {
        if (takerFeeRate == 0) return 0;
        return (amount * takerFeeRate + BPS_DIVISOR - 1) / BPS_DIVISOR;
    }

    function _calculateMakerFee(uint256 amount) internal view returns (uint256) {
        if (makerFeeRate == 0) return 0;
        return (amount * makerFeeRate + BPS_DIVISOR - 1) / BPS_DIVISOR;
    }

    function _calculateFeeWithRate(uint256 amount, uint256 feeRateBps) internal pure returns (uint256) {
        if (feeRateBps == 0) return 0;
        return (amount * feeRateBps + BPS_DIVISOR - 1) / BPS_DIVISOR;
    }

    function _validateFeeRate(uint256 feeRateBps) internal pure {
        require(feeRateBps <= MAX_FEE_RATE, "Fee rate too high");
    }

    function _setTakerFeeRate(uint256 newRate) internal {
        if (newRate > MAX_FEE_RATE) revert FeeRateTooHigh();

        uint256 oldRate = takerFeeRate;
        takerFeeRate = newRate;

        emit TakerFeeRateUpdated(oldRate, newRate, msg.sender);
    }

    function _setMakerFeeRate(uint256 newRate) internal {
        if (newRate > MAX_FEE_RATE) revert FeeRateTooHigh();

        uint256 oldRate = makerFeeRate;
        makerFeeRate = newRate;

        emit MakerFeeRateUpdated(oldRate, newRate, msg.sender);
    }

    function _setFeeRecipient(address newRecipient) internal {
        if (newRecipient == address(0)) revert InvalidFeeRecipient();

        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;

        emit FeeRecipientUpdated(oldRecipient, newRecipient, msg.sender);
    }
}
