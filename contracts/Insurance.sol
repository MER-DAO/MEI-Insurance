// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import './interfaces/IBaseOracle.sol';
import "./interfaces/IPancakePair.sol";

// This contract is owned by Timelock.
contract Insurance is Ownable {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    uint256 constant RATIO_BASE = 100;
    uint256 constant RATE_BASE = 10000;

    address public feeTo;
    uint256 public platformFeeRate = 50;  // 0.5%
    bool public onlyClaimAfterMarketClose = true;

    address public wbnb;
    IBaseOracle tokenPriceOracle;
    IBaseOracle pairPriceOracle;

    mapping(address => bool) public isStableToken;

    struct Market {
        address lpToken;
        address tokenA;
        address tokenB;  // stable token or WBNB

        uint256 expiration;
        uint256 paymentRatio;  // payment / loss

        // There is a minimum amount for seller to prevent dust orders.
        uint256 minimumAmount;
    }

    mapping(uint256 => Market) public marketMap;

    struct Order {
        uint256 rate;  // premium / staked asset
        uint256 amount;  // staked asset (of stable token or WBNB)
    }

    // marketId => who => Order[]
    mapping(uint256 => mapping(address => Order[])) public orderMap;

    // marketId => closeingPrice
    mapping(uint256 => uint256) public priceMap;

    struct Policy {
        uint256 premium;  // The amount the buyer paid.
        address buyer;  // The address of the buyer.
        address seller;  // The address of the seller.
        uint256 stakedAmount;  // The maximum amount the policy can pay.
        uint256 lpAmount;  // The amount of staked LP token by the buyer.
        uint256 lpValue;  // The estimated value of the staked LP token when buying.
        bool claimed;
    }

    // policyArray by index
    Policy[] public policyArray;

    // marketId => buyer => Policy[]
    mapping(uint256 => mapping(address => uint256[])) public buyerPolicyIndexMap;
    // marketId => seller => Policy[]
    mapping(uint256 => mapping(address => uint256[])) public sellerPolicyIndexMap;

    event CreateMarket(address _who, uint256 _marketId, address _lpToken, address _tokenA, address _tokenB,
                       uint256 _expiration, uint256 _paymentRatio, uint256 _minimumAmount);
    event Sell(address _who, uint256 _marketId, uint256 _index, uint256 _rate, uint256 _amount);
    event ChangeOrCancel(address _who, uint256 _marketId, uint256 _index, uint256 _newAmount);
    event Update(address _who, uint256 _marketId, uint256 _index, uint256 _newAmount);
    event Buy(address _who, uint256 _marketId, uint256 _buyIndex, address _seller, uint256 _sellIndex, uint256 _index,
              uint256 _amount, uint256 _lpTokenAmount, uint256 _lpValue, uint256 _premium, uint256 _fee);
    event Claim(address _buyer, uint256 _marketId, uint256 _index);
    event Refund(address _seller,uint256 _marketId, uint256 _index);      
    event CloseMarket(uint256 _marketId);

    constructor(IBaseOracle _tokenPriceOracle, IBaseOracle _pairPriceOracle, address _wbnb) public {
        tokenPriceOracle = _tokenPriceOracle;
        pairPriceOracle = _pairPriceOracle;
        wbnb = _wbnb;
    }

    function setFeeTo(address _feeTo) external onlyOwner {
        feeTo = _feeTo;
    }

    function setPlatformFeeRate(uint256 _feeRate) external onlyOwner {
        require(platformFeeRate < RATE_BASE, "Invalid value");
        platformFeeRate = _feeRate;
    }

    function setOnlyClaimAfterMarketClose(bool _value) external onlyOwner {
        onlyClaimAfterMarketClose = _value;
    }

    function setTokenPriceOracle(IBaseOracle _tokenPriceOracle) external onlyOwner {
        tokenPriceOracle = _tokenPriceOracle;
    }

    function setPairPriceOracle(IBaseOracle _pairPriceOracle) external onlyOwner {
        pairPriceOracle = _pairPriceOracle;
    }

    function setStableToken(address _token, bool _isStable) external onlyOwner {
        isStableToken[_token] = _isStable;
    }

    function createMarket(uint256 _marketId, address _lpToken, uint256 _expiration, uint256 _paymentRatio, uint256 _minimumAmount) external onlyOwner {
        require(marketMap[_marketId].lpToken == address(0), "Market already exists");

        require(_lpToken != address(0), "Should be a valid LP");
        require(_expiration > now, "Should be a future time");

        marketMap[_marketId].lpToken = _lpToken;
        marketMap[_marketId].expiration = _expiration;
        marketMap[_marketId].paymentRatio = _paymentRatio;
        marketMap[_marketId].minimumAmount = _minimumAmount;

        address token0 = IPancakePair(_lpToken).token0();
        address token1 = IPancakePair(_lpToken).token1();

        if (isStableToken[token0]) {
            marketMap[_marketId].tokenA = token1;
            marketMap[_marketId].tokenB = token0;
        } else if (isStableToken[token1]) {
            marketMap[_marketId].tokenA = token0;
            marketMap[_marketId].tokenB = token1;
        } else if (token0 == wbnb) {
            marketMap[_marketId].tokenA = token1;
            marketMap[_marketId].tokenB = token0;
        } else if (token1 == wbnb) {
            marketMap[_marketId].tokenA = token0;
            marketMap[_marketId].tokenB = token1;
        } else {
            require(false, "One token needs to be stable token or wbnb");
        }

        emit CreateMarket(msg.sender, _marketId, _lpToken, marketMap[_marketId].tokenA,
            marketMap[_marketId].tokenB, _expiration, _paymentRatio, _minimumAmount);
    }

    function sell(uint256 _marketId, uint256 _rate, uint256 _amount) external {
        require(marketMap[_marketId].lpToken != address(0), "market should exist");
        require(now < marketMap[_marketId].expiration, "market expired");
        require(_amount >= marketMap[_marketId].minimumAmount, "order too small");

        // Create the order.
        Order memory order;
        order.rate = _rate;
        order.amount = _amount;
        orderMap[_marketId][msg.sender].push(order);

        // Stake the asset.
        IERC20(marketMap[_marketId].tokenB).safeTransferFrom(msg.sender, address(this), _amount);

        emit Sell(msg.sender, _marketId, orderMap[_marketId][msg.sender].length - 1, _rate, _amount);
    }

    function changeOrCancel(uint256 _marketId, uint256 _index, uint256 _newAmount) external {
        require(marketMap[_marketId].lpToken != address(0), "market should exist");

        // We allow user to cancel order after market expires, but doesn't allow them to update.
        if (_newAmount > 0) {
            require(now < marketMap[_marketId].expiration, "market expired");
        }

        require(_newAmount == 0 || _newAmount >= marketMap[_marketId].minimumAmount, "order too small and not 0");

        // Change or cancel the order.
        uint256 oldAmount = orderMap[_marketId][msg.sender][_index].amount;
        orderMap[_marketId][msg.sender][_index].amount = _newAmount;

        // Add or reduce amount.
        if (_newAmount > oldAmount) {
            IERC20(marketMap[_marketId].tokenB).safeTransferFrom(msg.sender, address(this), _newAmount - oldAmount);
        } else {
            IERC20(marketMap[_marketId].tokenB).safeTransfer(msg.sender, oldAmount - _newAmount);
        }

        emit ChangeOrCancel(msg.sender, _marketId, _index, _newAmount);
    }

    function buy(uint256 _marketId, address _seller, uint256 _index, uint256 _amount, uint256 _lpTokenAmount) external {
        require(marketMap[_marketId].lpToken != address(0), "market should exist");
        require(now < marketMap[_marketId].expiration, "market expired");
        require(_amount >= marketMap[_marketId].minimumAmount, "order too small");
        require(_amount <= orderMap[_marketId][_seller][_index].amount, "not enough amount");

        orderMap[_marketId][_seller][_index].amount = orderMap[_marketId][_seller][_index].amount.sub(_amount);

        // Update event
        emit Update(_seller, _marketId, _index, orderMap[_marketId][_seller][_index].amount);

        // Set up the policy.
        Policy memory policy;
        policy.premium = _amount.mul(orderMap[_marketId][_seller][_index].rate).div(RATE_BASE);
        policy.buyer = msg.sender;
        policy.seller = _seller;
        policy.stakedAmount = _amount;
        policy.lpAmount = _lpTokenAmount;
        policy.lpValue = estimateBaseTokenAmount(_marketId, _lpTokenAmount);

        buyerPolicyIndexMap[_marketId][msg.sender].push(policyArray.length);
        sellerPolicyIndexMap[_marketId][_seller].push(policyArray.length);
        policyArray.push(policy);

        // Pay the premium to seller immediately, but deduct a fee.
        uint256 fee = 0;
        if (feeTo != address(0)) {
          fee = policy.premium.mul(platformFeeRate).div(RATE_BASE);
          IERC20(marketMap[_marketId].tokenB).safeTransferFrom(msg.sender, _seller, policy.premium.sub(fee));
          IERC20(marketMap[_marketId].tokenB).safeTransferFrom(msg.sender, feeTo, fee);
        } else {
          IERC20(marketMap[_marketId].tokenB).safeTransferFrom(msg.sender, _seller, policy.premium);
        }

        // Stake the LP token.
        IERC20(marketMap[_marketId].lpToken).safeTransferFrom(msg.sender, address(this), _lpTokenAmount);

        emit Buy(msg.sender, _marketId, buyerPolicyIndexMap[_marketId][msg.sender].length - 1,
            _seller, sellerPolicyIndexMap[_marketId][_seller].length - 1, _index, _amount,
            _lpTokenAmount, policy.lpValue, policy.premium, fee);
    }

    // Price is multiplied by 2 ** 112
    function getLpTokenPrice(address _lpToken, address _baseToken) public view returns(uint256) {
        uint price;

        if (_baseToken == wbnb) {
            price = pairPriceOracle.getBNBPx(_lpToken);
        } else {
            price = pairPriceOracle.getBNBPx(_lpToken).mul(2 ** 56).div(tokenPriceOracle.getBNBPx(_baseToken).div(2 ** 56));
        }

        return uint256(price);
    }

    // Estimate the price of the _lpToken in _baseToken.
    function estimateBaseTokenAmount(uint256 _marketId, uint256 _lpTokenAmount) public view returns(uint256) {
        uint256 price;

        if (priceMap[_marketId] > 0) {
            price = priceMap[_marketId];
        } else {
            price = getLpTokenPrice(marketMap[_marketId].lpToken, marketMap[_marketId].tokenB);
        }

        return uint256(_lpTokenAmount.mul(price).div(2**112));
    }

    // Called by the buyer before or after market closes.
    function claim(uint256 _marketId, uint256 _buyerPolicyIndex) public {
        require(marketMap[_marketId].lpToken != address(0), "market should exist");

        if (onlyClaimAfterMarketClose) {
            require(now >= marketMap[_marketId].expiration, "only after market closes");
        }

        if (now >= marketMap[_marketId].expiration && priceMap[_marketId] == 0) {
            _closeMarketPrivate(_marketId);
        }

        uint256 realIndex = buyerPolicyIndexMap[_marketId][msg.sender][_buyerPolicyIndex];
        Policy storage policy = policyArray[realIndex];
        _claimOrRefund(_marketId, policy);
        emit Claim(msg.sender, _marketId, _buyerPolicyIndex);
    }

    // Called by the seller after market closes.
    function refund(uint256 _marketId, uint256 _sellerPolicyIndex) public {
        require(marketMap[_marketId].lpToken != address(0), "market should exist");
        require(now >= marketMap[_marketId].expiration, "only after market closes");

        if (priceMap[_marketId] == 0) {
            _closeMarketPrivate(_marketId);
        }

        uint256 realIndex = sellerPolicyIndexMap[_marketId][msg.sender][_sellerPolicyIndex];
        Policy storage policy = policyArray[realIndex];
        _claimOrRefund(_marketId, policy);
        emit Refund(msg.sender, _marketId, _sellerPolicyIndex);
    }

    // Called by anyone.
    function closeMarket(uint256 _marketId) public {
        require(marketMap[_marketId].lpToken != address(0), "market should exist");
        require(now >= marketMap[_marketId].expiration, "market not expired");

        _closeMarketPrivate(_marketId);

        emit CloseMarket(_marketId);
    }

    function _closeMarketPrivate(uint256 _marketId) private {
        priceMap[_marketId] = getLpTokenPrice(marketMap[_marketId].lpToken, marketMap[_marketId].tokenB);
    }

    function _claimOrRefund(uint256 _marketId, Policy storage _policy) private {
        require(!_policy.claimed, "already claimed");

        // Calculate loss.
        uint256 currentLpValue = estimateBaseTokenAmount(_marketId, _policy.lpAmount);

        uint256 coveredLoss = 0;
        uint256 toPayAmount = 0;

        if (currentLpValue < _policy.lpValue) {

            coveredLoss = _policy.lpValue.sub(currentLpValue).mul(marketMap[_marketId].paymentRatio).div(RATIO_BASE);
            toPayAmount = coveredLoss < _policy.stakedAmount ? coveredLoss : _policy.stakedAmount;

            // Cover the loss.
            IERC20(marketMap[_marketId].tokenB).safeTransfer(_policy.buyer, toPayAmount);
        }

        _policy.claimed = true;

        // Refund the remaining to seller.
        uint256 refundAmount = _policy.stakedAmount.sub(toPayAmount);
        if (refundAmount > 0) {
          IERC20(marketMap[_marketId].tokenB).safeTransfer(_policy.seller, refundAmount);
        }

        // Refund the LP token to the buyer.
        IERC20(marketMap[_marketId].lpToken).safeTransfer(_policy.buyer, _policy.lpAmount);
    }

    function buyerPolicyMap(uint256 _marketId, address _buyer, uint256 _buyerPolicyIndex) public view returns(Policy memory) {
        uint256 realIndex = buyerPolicyIndexMap[_marketId][_buyer][_buyerPolicyIndex];
        return policyArray[realIndex];
    }

    function sellerPolicyMap(uint256 _marketId, address _seller, uint256 _sellerPolicyIndex) public view returns(Policy memory) {
        uint256 realIndex = sellerPolicyIndexMap[_marketId][_seller][_sellerPolicyIndex];
        return policyArray[realIndex];
    }
}
