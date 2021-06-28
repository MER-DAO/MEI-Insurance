
pragma solidity 0.6.12;

import '@openzeppelin/contracts/math/SafeMath.sol';

import './UsingBaseOracle.sol';
import '../utils/HomoraMath.sol';
import '../interfaces/IBaseOracle.sol';
import '../interfaces/IPancakePair.sol';

contract PairPriceOracle is UsingBaseOracle, IBaseOracle {
  using SafeMath for uint;
  using HomoraMath for uint;

  constructor(IBaseOracle _base) public UsingBaseOracle(_base) {}

  /// @dev Return the value of the given input as BNB per unit, multiplied by 2**112.
  /// @param pair The Pancake pair to check the value.
  function getBNBPx(address pair) external view override returns (uint) {
    address token0 = IPancakePair(pair).token0();
    address token1 = IPancakePair(pair).token1();
    uint totalSupply = IPancakePair(pair).totalSupply();
    (uint r0, uint r1, ) = IPancakePair(pair).getReserves();
    uint sqrtK = HomoraMath.sqrt(r0.mul(r1)).fdiv(totalSupply); // in 2**112
    uint px0 = base.getBNBPx(token0);
    uint px1 = base.getBNBPx(token1);
    return sqrtK.mul(2).mul(HomoraMath.sqrt(px0)).div(2**56).mul(HomoraMath.sqrt(px1)).div(2**56);
  }
}
