pragma solidity 0.6.12;

interface IBaseOracle {
  /// @dev Return the value of the given input as BNB per unit, multiplied by 2**112.
  /// @param token The BEP-20 token to check the value.
  function getBNBPx(address token) external view returns (uint);
}
