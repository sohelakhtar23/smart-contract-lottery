/* Layout of Contract:
    version
    imports
    errors
    interfaces, libraries, contracts
    Type declarations
    State variables
    Events
    Modifiers
    Functions
*/

/* Layout of Functions:
    constructor
    receive function (if exists)
    fallback function (if exists)
    external
    public
    internal
    private
    view & pure functions
*/


// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/**
 * @title A simple Raffle contract
 * @author Sohel Akhtar
 * @notice This contract is for creating a simple raffle system
 * @dev It implements Chainlink VRFv2.5 and Chainlink Automation
 */

contract Raffle is VRFConsumerBaseV2Plus {
    /* Errors */
    error Raffle__SendMoreToEnterRaffle();
    error Raffle__TransferFailed();
    error Raffle__RaffleNotOpen();
    error Raffle__UpkeepNotNeeded(uint256 currentBalance, uint256 numPlayers, uint256 raffleState);

    /* Type Declarations */
    enum RaffleState {
        OPEN,       //0
        CALCULATING //1
    }

    /* State Variables */
    // Lottery Variables
    uint256 private immutable i_entranceFee;
    uint256 private immutable i_interval; // Duration of the lottery in seconds
    address payable[] private s_players;
    uint256 private s_lastTimeStamp;
    address private s_recentWinner;
    RaffleState private s_raffleState;

    // Chainlink VRF Variables
    bytes32 private immutable i_keyHash;
    uint256 private immutable i_subscriptionId;
    uint32 private immutable i_callbackGasLimit;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1;

    /* Events */
    event RaffleEntered(address indexed player);
    event WinnerPicked(address indexed winner);
    event RequestedRaffleWinner(uint256 indexed requestId);

    constructor(uint256 _entranceFee, uint256 _interval, address _vrfCoordinator, bytes32 _keyHash, uint256 _subscriptionId, uint32 _callbackGasLimit) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        i_entranceFee = _entranceFee;
        i_interval = _interval;
        i_keyHash = _keyHash;
        i_subscriptionId = _subscriptionId;
        i_callbackGasLimit = _callbackGasLimit;
        s_lastTimeStamp = block.timestamp;
        s_raffleState = RaffleState.OPEN;
    }

    function enterRaffle() public payable {
        if(msg.value < i_entranceFee) {
            revert Raffle__SendMoreToEnterRaffle();
        }
        if(s_raffleState != RaffleState.OPEN) {
            revert Raffle__RaffleNotOpen();
        }

        s_players.push(payable(msg.sender));
        emit RaffleEntered(msg.sender);

    }
    
    /* going to use Chainlink Automation to automate the process of picking a winner and restarting the lottery. 
    So commenting out the initial pickWinner() and instead, implement the Chainlink Automation functions  
    The Chainlink Keeper nodes will call the `checkUpkeep` function to check if it's time to pick a winner, 
    and if it returns true, they will call the `performUpkeep` function to pick a winner and restart the lottery. 

    function pickWinner() public {
        if((block.timestamp - s_lastTimeStamp) < i_interval) {
            revert() ;
        }
        s_raffleState = RaffleState.CALCULATING;

        s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: i_keyHash,
                subId: i_subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: i_callbackGasLimit,
                numWords: NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
            })
        );
    }
    */

    /**
     * @dev This is the function that the Chainlink Keeper nodes call
     * they look for `upkeepNeeded` to return True.
     * the following should be true for this to return true:
     * 1. The time interval has passed between raffle runs.
     * 2. The lottery is open.
     * 3. The contract has ETH. (have players)
     * 4. Implicitly, your subscription is funded with LINK.
     * @param - ignored
     * @return upKeepNeeded - true if it's time to restart the lottery
     */

    function checkUpkeep(
        bytes memory /*callData*/
    ) public view returns (bool upKeepNeeded, bytes memory /*performData */) {
        bool isTimePassed = (block.timestamp - s_lastTimeStamp) > i_interval;
        bool isLotteryOpen = s_raffleState == RaffleState.OPEN;
        bool hasBalance = address(this).balance > 0;
        bool hasPlayers = s_players.length > 0;
        upKeepNeeded = isTimePassed && isLotteryOpen && hasBalance && hasPlayers;
        return (upKeepNeeded, bytes(""));
    }

    /**
     * @dev Once `checkUpkeep` is returning `true`, this function is called
     * and it kicks off a Chainlink VRF call to get a random winner.
     */
    function performUpkeep(bytes calldata /* performData */) external  {
        (bool upKeepNeeded, ) = checkUpkeep("");
        if(!upKeepNeeded) {
            revert Raffle__UpkeepNotNeeded(address(this).balance, s_players.length, uint256(s_raffleState));
        }
        s_raffleState = RaffleState.CALCULATING;
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: i_keyHash,
                subId: i_subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: i_callbackGasLimit,
                numWords: NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
            })
        );
        // Quiz... is this redundant?
        emit RequestedRaffleWinner(requestId);
    }

    /**
     * @dev This is the function that Chainlink VRF node
     * calls to send the money to the random winner.
     */
    function fulfillRandomWords(uint256 /*requestId*/, uint256[] calldata randomWords) internal override {
        uint256 indexOfWinner = randomWords[0] % s_players.length;
        address payable recent_winner = s_players[indexOfWinner];
        s_recentWinner = recent_winner;
        s_raffleState = RaffleState.OPEN;
        s_players = new address payable[](0);
        s_lastTimeStamp = block.timestamp;

        (bool success,) = recent_winner.call{value: address(this).balance}("");
        if(!success) {
            revert Raffle__TransferFailed();
        }
        emit WinnerPicked(recent_winner);
    }

    /**
     * Getter Functions
     */
    function getEntranceFee() external view returns (uint256) {
        return i_entranceFee;
    }
    function getRaffleState() external view  returns (RaffleState) {
        return s_raffleState;
    }
    function getPlayer(uint256 index) external view returns (address) {
        return s_players[index];
    }
    function getLastTimeStamp() external view returns (uint256) {
        return s_lastTimeStamp;
    }
    function getRecentWinner() external view returns (address) {
        return s_recentWinner;
    }
}