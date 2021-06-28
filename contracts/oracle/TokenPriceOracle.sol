pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import '../interfaces/IBaseOracle.sol';

interface TokenWithSymbol {
  function symbol() external view returns (string memory);
}

interface IBandReference {
  /// A structure returned whenever someone requests for standard reference data.
  struct ReferenceData {
    uint256 rate; // base/quote exchange rate, multiplied by 1e18.
    uint256 lastUpdatedBase; // UNIX epoch of the last time when base price gets updated.
    uint256 lastUpdatedQuote; // UNIX epoch of the last time when quote price gets updated.
  }

  /// Returns the price data for the given base/quote pair. Revert if not available.
  function getReferenceData(string memory _base, string memory _quote)
    external
    view
    returns (ReferenceData memory);

  /// Similar to getReferenceData, but with multiple base/quote pairs at once.
  function getReferenceDataBulk(string[] memory _bases, string[] memory _quotes)
    external
    view
    returns (ReferenceData[] memory);
}

contract TokenPriceOracle is IBaseOracle, Ownable {

  IBandReference public ref;

  address public immutable wbnb;

  mapping(address => string) public symbolMap;

  // BSC (Testnet): 0xDA7a001b254CD22e46d3eAB04d937489c93174C3
  // BSC (Mainnet): 0xDA7a001b254CD22e46d3eAB04d937489c93174C3
  constructor(IBandReference _ref, address _wbnb) public {
    ref = _ref;
    wbnb = _wbnb;
  }

  function setSymbol(address _token, string memory _symbol) external onlyOwner {
    symbolMap[_token] = _symbol;
  }

  /// @dev Return the value of the given input as BNB per unit, multiplied by 2**112.
  /// @param _token The BEP-20 token to check the value.
  function getBNBPx(address _token) external view override returns (uint) {
    if (_token == wbnb) {
      return 2**112;
    }

    require(bytes(symbolMap[_token]).length > 0, "token not supported");

    IBandReference.ReferenceData memory data = ref.getReferenceData(symbolMap[_token], "BNB");
    return data.rate * (2**112) / 1e18;
  }
}
