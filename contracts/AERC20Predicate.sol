//SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

// import "hardhat/console.sol";

import {IERC20} from "./interfaces/IERC20.sol";
import {LibERC20} from "./libraries/LibERC20.sol";
import "./libraries/LibMath.sol";
import {RLPReader} from "./libraries/RLPReader.sol";
import {ITokenPredicate} from "./interfaces/ITokenPredicate.sol";

interface ILendingPool {
    function getReserveNormalizedIncome(address _asset) external view returns (uint256);
}

interface IAToken {
    function POOL() external returns(ILendingPool);
    function UNDERLYING_ASSET_ADDRESS() external returns(address);
}

struct AppStorage {    
    address manager; 
    bool init;
}

contract ERC20Predicate is ITokenPredicate {
    AppStorage s;
    using RLPReader for bytes;
    using RLPReader for RLPReader.RLPItem;  

    modifier onlyManager() {
        require(s.manager == msg.sender, "Caller is not manager");
        _;
    }
        
    bytes32 public constant TRANSFER_EVENT_SIG = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    event LockedERC20(
        address indexed depositor,
        address indexed depositReceiver,
        address indexed rootToken,
        uint256 amount
    );        

    function initialize(address _manager) external {
        require(!s.init, "Already initialized");
        s.init = true;
        s.manager = _manager;
    }


    function getMATokenValue(address _aTokenAddress, uint256 _aTokenValue) external returns (uint256 maTokenValue_) {
        ILendingPool pool = IAToken(_aTokenAddress).POOL();
        uint256 liquidityIndex = pool.getReserveNormalizedIncome(IAToken(_aTokenAddress).UNDERLYING_ASSET_ADDRESS());
        maTokenValue_ = LibMath.p27Div(_aTokenValue, liquidityIndex);        
    }

    /**
     * @notice Lock ERC20 tokens for deposit, callable only by manager
     * @param depositor Address who wants to deposit tokens
     * @param depositReceiver Address (address) who wants to receive tokens on child chain
     * @param rootToken Token which gets deposited
     * @param depositData ABI encoded amount
     */
    function lockTokens(
        address depositor,
        address depositReceiver,
        address rootToken,
        bytes calldata depositData
    )
        external
        override
        onlyManager()
    {
        (uint256 maTokenValue, uint256 maxATokenValue) = abi.decode(depositData, (uint256, uint256));
        ILendingPool pool = IAToken(rootToken).POOL();
        uint256 liquidityIndex = pool.getReserveNormalizedIncome(IAToken(rootToken).UNDERLYING_ASSET_ADDRESS());
        uint256 aTokenValue = LibMath.p27Mul(maTokenValue, liquidityIndex);
        require(aTokenValue <= maxATokenValue, "Too much aToken slippage occurred on transfer to matic");                    
        emit LockedERC20(depositor, depositReceiver, rootToken, aTokenValue);
        LibERC20.transferFrom(rootToken, depositor, address(this), aTokenValue);        
    }

    /**
     * @notice Validates log signature, from and to address
     * then sends the correct amount to withdrawer
     * callable only by manager
     * @param rootToken Token which gets withdrawn
     * @param log Valid ERC20 burn log from child chain
     */
    function exitTokens(
        address,
        address rootToken,
        bytes memory log
    )
        public
        override
        onlyManager()
    {
        RLPReader.RLPItem[] memory logRLPList = log.toRlpItem().toList();
        RLPReader.RLPItem[] memory logTopicRLPList = logRLPList[1].toList(); // topics

        require(
            bytes32(logTopicRLPList[0].toUint()) == TRANSFER_EVENT_SIG, // topic0 is event sig
            "ERC20Predicate: INVALID_SIGNATURE"
        );

        address withdrawer = address(logTopicRLPList[1].toUint()); // topic1 is from address

        require(
            address(logTopicRLPList[2].toUint()) == address(0), // topic2 is to address
            "ERC20Predicate: INVALID_RECEIVER"
        );
        uint256 maTokenAmount = logRLPList[2].toUint();
        ILendingPool pool = IAToken(rootToken).POOL();
        uint256 liquidityIndex = pool.getReserveNormalizedIncome(IAToken(rootToken).UNDERLYING_ASSET_ADDRESS());
        uint256 aTokenAmount = LibMath.p27Mul(maTokenAmount, liquidityIndex);
        LibERC20.transfer(
            rootToken, 
            withdrawer,
            aTokenAmount
        );
    }
}
