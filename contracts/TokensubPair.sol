// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "./TokensubERC20.sol";
import "./interfaces/ITokensubPair.sol";
import "./libraries/Math.sol";
import "./libraries/UQ112x112.sol";
import "./interfaces/ITokensubFactory.sol";
import "./interfaces/ITokensubCallee.sol";
import './interfaces/IERC20.sol';

/*
    Implements the actual pool that exchanges tokens
*/

contract TokensubPair is ITokensubPair, TokensubERC20 {
    using SafeMath for uint256;
    using UQ112x112 for uint224;

    uint256 public constant MINIMUM_LIQUIDITY = 10**3;  // to avoid cases of division by zero
    bytes4 private constant SELECTOR = // ABI selector for the ERC-20 transfer function, used to transfer ERC20 tokens in the two token accounts
        bytes4(keccak256(bytes("transfer(address,uint256)")));  

    address public factory;  // address of the pool creator
    address public token0;   // token0 is worth reserve1/reserve0 token1's
    address public token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;  // timestamp for the last block in which an exchange occurred, used to track exchange rates across time

    /* These variables hold the cumulative costs for each token (each in term of the other). 
    They can be used to calculate the average exchange rate over a period of time. */
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint256 public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event
                          // changes when lp deposits or withdraw token. Also slighly increases because of 0.3% market fee

    // Prevents reentracy attacks
    // prevent functions from being called while they are running (within the same transaction)
    uint256 private unlocked = 1;
    modifier lock() {
        // sandwich modifier
        require(unlocked == 1, "Tokensub: LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    // provides callers with the current state of the exchange
    function getReserves()
        public
        view
        returns (
            uint112 _reserve0,
            uint112 _reserve1,
            uint32 _blockTimestampLast
        )
    {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    /* Transfers an amount of ERC20 tokens from the exchange to somebody else. 
    SELECTOR specifies that the function we are calling is transfer(address,uint) 

    There are two ways in which an ERC-20 transfer call can report failure:
        1.) Revert. If a call to an external contract reverts than the boolean return value is false
        2.) End normally but report a failure. In that case the return value buffer has a non-zero length, 
        and when decoded as a boolean value it is false
    If either of these conditions happen, revert    
    */
    function _safeTransfer(
        address token,
        address to,
        uint256 value
    ) private {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(SELECTOR, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "Tokensub: TRANSFER_FAILED"
        );
    }

    /*
    // These two events are emitted when a liquidity provider either deposits liquidity (Mint) or withdraws it (Burn)
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        address indexed to
    );

    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );

    // emitted every time tokens are added or withdrawn, regardless of the reason, 
    // to provide the latest reserve information (and therefore the exchange rate)
    event Sync(uint112 reserve0, uint112 reserve1);
    */

    constructor() {
      factory = msg.sender;
    }

    // called once by the factory at time of deployment to specify the two ERC-20 tokens that this pair will exchange
    function initialize(address _token0, address _token1) external {
      require(msg.sender == factory, "Tokensub: FORBIDDEN"); 
      token0 = _token0;
      token1 = _token1;
    }

    // update reserves and, on the first call per block, price accumulators
    // called every time tokens are deposited or withdrawn from the pool
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
      require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, 'Tokensub: OVERFLOW');
      uint32 blockTimestamp = uint32(block.timestamp % 2**32);
      uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
      // If the time elapsed is not zero, it means we are the first exchange transaction on this block. 
      // In that case, we need to update the cost accumulators.
      if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
        // never flows, and + overflow is desired
        price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
        price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
      }
      reserve0 = uint112(balance0);
      reserve1 = uint112(balance1);
      blockTimestampLast = blockTimestamp;
      emit Sync(reserve0, reserve1);
    }


    /*
    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    // This fee is only calculated when liquidity is added or remmoved from the pool(to reduce gas costs)
    The liquidity providers get their cut simply by the appreciation of their liquidity tokens. 
    But the protocol fee requires new liquidity tokens to be minted and provided to the feeTo address.
    */
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = ITokensubFactory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint _kLast = kLast; // gas savings - KLast is in storage, _kLast is in internal function memory
        if(feeOn) {
            if(_kLast != 0) {
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    /* We know that between the time kLast was calculated and the present 
                    no liquidity was added or removed (because we run this calculation every time liquidity is added or removed,
                     before it actually changes), so any change in reserve0 * reserve1 has to 
                     come from transaction fees (without them we'd keep reserve0 * reserve1 constant).
                    */
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        }
        /* If there is no fee set kLast to zero (if it isn't that already). 
        When this contract was written there was a gas refund feature that 
        encouraged contracts to reduce the overall size of the Ethereum state 
        by zeroing out storage they did not need. This code gets that refund when possible */
        else if (_kLast != 0) {
            kLast = 0;
        }
    } 

    /*
        IMPORTNANT: The following functions are designed to be called from the periphery coontract
    */

    // this low-level function should be called from a contract which performs important safety checks
    /*  called when a liquidity provider adds liquidity to the pool. 
    It mints additional liquidity tokens as a reward. It should be 
    called from a periphery contract that calls it after adding 
    the liquidity in the same transaction (so nobody else would be able to submit 
    a transaction that claims the new liquidity before the legitimate owner).
    */
    function mint(address to) external lock returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if(_totalSupply == 0) {
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        }
        else {
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'Tokensub: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        if(feeOn) {
            kLast = uint(reserve0).mul(reserve1);  // reserve0 and reserve1 are up to date
        }
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low level function should be called from a contract which performs important safety checks
    /* This function is called when liquidity is withdrawn and the appropriate 
    liquidity tokens need to be burned. Is should also be called from a periphery account.
    */
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves();
        address _token0 = token0;
        address _token1 = token1;
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        if(feeOn) {
            kLast = uint(reserve0).mul(reserve1);  // reserve0 and reserve1 are up to date
        }
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = token0;
        address _token1 = token1;
        require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        if (data.length > 0) ITokensubCallee(to).tokensubCall(msg.sender, amount0Out, amount1Out, data);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
