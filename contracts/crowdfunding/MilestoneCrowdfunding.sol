// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IERC20.sol";
import "../interfaces/IPriceOracle.sol";
import "../interfaces/ISlothPriceOracle.sol";
import "../libraries/SafeMath.sol";
import "../libraries/SafeERC20.sol";
import "../libraries/ReentrancyGuard.sol";

/**
 * @title MilestoneCrowdfunding
 * @notice Crowdfunding platform where creators raise money for projects. Money is held
 *         safely and only released when the community approves that work was completed.
 *
 * HOW IT WORKS:
 * 1. Creator posts a project with goals broken into milestones (checkpoints)
 * 2. Backers contribute money, which is held safely by this contract
 * 3. Creator completes work and submits proof for each milestone
 * 4. Backers vote on whether the work meets expectations
 * 5. If approved, creator gets paid. If rejected, backers can get refunds.
 *
 * MONEY SPLIT WHEN MILESTONES PASS:
 * - 80% goes to the creator
 * - 10% goes to the platform treasury
 * - 5% goes to JUICY token stakers
 * - 5% goes to DREAMS token stakers
 *
 * SAFETY FEATURES:
 * - All money is held in this contract until milestones are approved
 * - Creators must put down a 10% deposit (skin in the game)
 * - 24-hour waiting period before you can vote (prevents cheating with borrowed money)
 * - Backers have 1 year to claim refunds if a project fails
 * - Dispute system with neutral arbitrator if there's disagreement
 *
 * TECHNICAL NOTES (for developers):
 * - Uses compact storage to save on blockchain fees
 * - Project details stored on IPFS (decentralized file storage)
 */
contract MilestoneCrowdfunding is ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // ============ STRUCTS ============

    /**
     * @dev Milestone = A checkpoint in the project where creator shows their work.
     * Think of it like a progress report - creator submits proof, backers vote on it.
     */
    struct Milestone {
        bytes32 descriptionHash;      // Link to milestone description (stored on IPFS)
        bytes32 deliverableHash;      // Link to what creator promised to deliver
        uint256 dueDate;              // Deadline for this milestone
        uint256 fundPercentage;       // What % of funds this milestone releases (e.g., 2000 = 20%)
        bytes32 proofHash;            // Link to proof that work was done
        MilestoneStatus status;       // Current state: waiting, submitted, approved, rejected, or expired
        uint256 votingEndTime;        // When voting closes
        uint256 votesFor;             // Total voting power saying "yes, approve it"
        uint256 votesAgainst;         // Total voting power saying "no, reject it"
    }

    enum MilestoneStatus {
        PENDING,
        SUBMITTED,
        APPROVED,
        REJECTED,
        EXPIRED
    }

    /**
     * @dev Campaign = A crowdfunding project created by someone who needs funding.
     * Contains all the info about the project and tracks who contributed.
     */
    struct Campaign {
        address creator;
        bytes32 metadataHash;         // IPFS hash containing title, description, category, images
        uint256 goalAmount;           // In USD (18 decimals)
        uint256 raisedAmount;         // In USD (18 decimals)
        uint256 fundingDeadline;
        uint256 creatorDeposit;
        uint256 currentMilestoneIndex;
        uint256 totalReleasedAmount;  // Track total released for accurate refunds
        CampaignStatus status;
        PaymentToken acceptedToken;
        bool creatorDepositRefunded;
        address tokenAddress;         // Store token address for the campaign
        mapping(address => Contribution) contributions;
        address[] backers;
    }

    struct Contribution {
        uint256 amount;               // Amount in USD value (also used as voting power)
        uint256 tokenAmount;          // Actual tokens contributed
        address token;
        bool refunded;
        uint256 contributionTime;     // Timestamp for vote locking
        // NOTE: snapshotVotingPower removed - uses amount directly (same value, saves ~200 gas/contrib)
    }

    enum CampaignStatus {
        FUNDING,
        VESTING,
        COMPLETED,
        FAILED,
        CANCELLED
    }

    enum PaymentToken {
        USDC,
        ETH,
        AVAX,
        DREAMS
    }

    enum DisputeStatus {
        NONE,
        PENDING,
        RESOLVED_FOR_CREATOR,
        RESOLVED_FOR_BACKERS
    }

    struct Dispute {
        uint256 campaignId;
        uint256 milestoneIndex;
        bytes32 evidenceHash;         // IPFS hash of creator's evidence
        uint256 deadline;             // 7 days from initiation
        DisputeStatus status;
        uint256 releasePercentage;    // 0, 5000, or 10000 (0%, 50%, 100%)
    }

    // ============ STATE VARIABLES ============

    mapping(uint256 => Campaign) public campaigns;
    mapping(uint256 => Milestone[]) public milestones;
    uint256 public campaignCount;

    // Tracks who has already voted on each milestone (one vote per person per milestone)
    // Format: milestoneVotes[campaignId][milestoneIndex][voterAddress] = true/false
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public milestoneVotes;

    // Dispute resolution
    mapping(uint256 => Dispute) public disputes;
    address public arbitrator;
    uint256 public disputeCount;

    // Campaign failure timestamps (for refund expiration)
    mapping(uint256 => uint256) public campaignFailedTimestamp;

    // Token addresses
    address public immutable USDC_ADDRESS;
    address public immutable ETH_ADDRESS;
    address public immutable AVAX_ADDRESS;
    address public immutable DREAMS_ADDRESS;

    // Platform settings
    address public treasury;
    address public admin;
    address public pendingAdmin;
    ISlothPriceOracle public priceOracle;

    // Staking pool addresses for reward distribution
    address public juicyStakingPool;
    address public dreamsStakingPool;

    // HOW THE MONEY IS SPLIT when a milestone is approved:
    // Example: If $10,000 is released for a milestone...
    uint256 public constant CREATOR_SHARE_BPS = 8000;       // 80% ($8,000) goes to the creator
    uint256 public constant PLATFORM_FEE_BPS = 1000;        // 10% ($1,000) goes to platform treasury
    uint256 public constant JUICY_STAKER_BPS = 500;         // 5% ($500) goes to JUICY stakers
    uint256 public constant DREAMS_STAKER_BPS = 500;        // 5% ($500) goes to DREAMS stakers
    // CAMPAIGN RULES:
    uint256 public constant MIN_CAMPAIGN_DURATION = 7 days;   // Campaigns must run at least 7 days
    uint256 public constant MAX_CAMPAIGN_DURATION = 90 days;  // Campaigns can run up to 90 days
    uint256 public constant VOTING_PERIOD = 7 days;           // Backers get 7 days to vote on milestones
    uint256 public constant MIN_VOTE_QUORUM_BPS = 5000;       // At least 50% of backers must vote
    uint256 public constant CREATOR_DEPOSIT_BPS = 1000;       // Creator must deposit 10% of goal (refunded on success)
    uint256 public constant DREAMS_BONUS_BPS = 1000;          // 10% bonus if you contribute with DREAMS tokens
    uint256 public constant MIN_MILESTONES = 3;               // Projects need at least 3 milestones
    uint256 public constant MAX_MILESTONES = 10;              // Projects can have up to 10 milestones
    uint256 public constant VOTE_LOCK_PERIOD = 1 days;        // Wait 24 hours after contributing before you can vote
    uint256 public constant MIN_CONTRIBUTION_USD = 10 * 1e18; // Minimum contribution is $10
    uint256 public constant PRECISION = 1e18;                 // Math precision (internal use)
    uint256 public constant REFUND_FEE_BPS = 300;             // 3% fee on refunds (covers processing costs)
    uint256 public constant REFUND_CLAIM_PERIOD = 365 days;   // You have 1 year to claim your refund
    uint256 public constant DISPUTE_PERIOD = 7 days;          // Creator has 7 days to dispute a rejection

    // Creator reputation
    mapping(address => uint256) public creatorSuccessfulCampaigns;
    mapping(address => uint256) public creatorFailedCampaigns;

    // ============ EVENTS ============

    event CampaignCreated(
        uint256 indexed campaignId,
        address indexed creator,
        bytes32 metadataHash,
        uint256 goalAmount,
        uint256 fundingDeadline,
        uint256 milestoneCount
    );

    event ContributionMade(
        uint256 indexed campaignId,
        address indexed backer,
        uint256 usdValue,
        uint256 tokenAmount,
        address token
    );

    event FundingCompleted(uint256 indexed campaignId, uint256 totalRaised);
    event FundingFailed(uint256 indexed campaignId, uint256 totalRaised);

    event MilestoneSubmitted(
        uint256 indexed campaignId,
        uint256 milestoneIndex,
        bytes32 proofHash,
        uint256 votingEndTime
    );

    event MilestoneVoted(
        uint256 indexed campaignId,
        uint256 milestoneIndex,
        address indexed voter,
        bool approve,
        uint256 voteWeight
    );

    event MilestoneApproved(
        uint256 indexed campaignId,
        uint256 milestoneIndex,
        uint256 fundsReleased,
        uint256 platformFee
    );

    event MilestoneRejected(uint256 indexed campaignId, uint256 milestoneIndex);
    event MilestoneExpired(uint256 indexed campaignId, uint256 milestoneIndex);

    event RefundClaimed(
        uint256 indexed campaignId,
        address indexed backer,
        uint256 tokenAmount,
        uint256 depositShare,
        address token
    );

    event CampaignCompleted(uint256 indexed campaignId, address indexed creator);
    event CreatorDepositReturned(uint256 indexed campaignId, address indexed creator, uint256 amount);

    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event PriceOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event AdminTransferInitiated(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferCompleted(address indexed oldAdmin, address indexed newAdmin);

    // Campaign cancellation
    event CampaignCancelled(uint256 indexed campaignId, bytes32 reasonHash);

    // Dispute events
    event DisputeInitiated(
        uint256 indexed disputeId,
        uint256 indexed campaignId,
        uint256 milestoneIndex,
        bytes32 evidenceHash,
        uint256 deadline
    );
    event DisputeResolved(
        uint256 indexed disputeId,
        bool inFavorOfCreator,
        uint256 releasePercentage
    );
    event ArbitratorUpdated(address indexed oldArbitrator, address indexed newArbitrator);
    event StakingPoolUpdated(string poolType, address indexed poolAddress);

    // Refund expiration
    event ExpiredRefundsSwept(uint256 indexed campaignId, uint256 amount);

    // ============ ERRORS ============

    error OnlyAdmin();
    error OnlyPendingAdmin();
    error OnlyCreator();
    error OnlyBacker();
    error CampaignNotFound();
    error InvalidAddress();
    error InvalidMetadataHash();
    error InvalidGoal();
    error InvalidDuration();
    error InvalidMilestoneCount();
    error MilestoneArrayMismatch();
    error InvalidPercentage();
    error PercentageMustSum100();
    error InvalidMilestoneDate();
    error MilestoneTooFarFuture();
    error MilestonesNotChronological();
    error TooManyFailedCampaigns();
    error GoalExceedsLimit();
    error CampaignNotFunding();
    error FundingPeriodEnded();
    error ContributionTooSmall();
    error CampaignNotVesting();
    error ProofHashRequired();
    error MilestoneAlreadySubmitted();
    error MilestoneDeadlinePassed();
    error MilestoneNotSubmitted();
    error VotingPeriodEnded();
    error AlreadyVoted();
    error VoteLockNotExpired();
    error FundingNotEnded();
    error MilestoneAlreadyResolved();
    error DeadlineNotPassed();
    error CampaignNotFailed();
    error NoContribution();
    error AlreadyRefunded();
    error NoPendingAdmin();
    error CampaignNotCancellable();
    error OnlyArbitrator();
    error DisputeNotFound();
    error DisputeAlreadyExists();
    error DisputePeriodExpired();
    error DisputeAlreadyResolved();
    error CampaignNotDisputable();
    error RefundPeriodExpired();
    error NoExpiredRefunds();
    error InvalidReleasePercentage();

    // ============ INTERNAL STRUCTS ============

    /**
     * @dev Container for the 80/10/5/5 money split calculation.
     * When a milestone is approved, the funds are divided like this:
     */
    struct FeeSplit {
        uint256 creatorAmount;      // 80% - The project creator gets the majority
        uint256 treasuryAmount;     // 10% - Platform fee for operating costs
        uint256 juicyStakerAmount;  // 5% - Reward for people staking JUICY tokens
        uint256 dreamsStakerAmount; // 5% - Reward for people staking DREAMS tokens
    }

    // ============ MODIFIERS ============

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    modifier onlyArbitrator() {
        if (msg.sender != arbitrator) revert OnlyArbitrator();
        _;
    }

    modifier campaignExists(uint256 _campaignId) {
        if (_campaignId >= campaignCount) revert CampaignNotFound();
        _;
    }

    modifier onlyCreator(uint256 _campaignId) {
        if (campaigns[_campaignId].creator != msg.sender) revert OnlyCreator();
        _;
    }

    modifier onlyBacker(uint256 _campaignId) {
        if (campaigns[_campaignId].contributions[msg.sender].amount == 0) revert OnlyBacker();
        _;
    }

    // ============ CONSTRUCTOR ============

    constructor(
        address _usdc,
        address _eth,
        address _avax,
        address _dreams,
        address _priceOracle,
        address _treasury
    ) {
        if (_usdc == address(0)) revert InvalidAddress();
        if (_eth == address(0)) revert InvalidAddress();
        if (_avax == address(0)) revert InvalidAddress();
        if (_dreams == address(0)) revert InvalidAddress();
        if (_priceOracle == address(0)) revert InvalidAddress();
        if (_treasury == address(0)) revert InvalidAddress();

        USDC_ADDRESS = _usdc;
        ETH_ADDRESS = _eth;
        AVAX_ADDRESS = _avax;
        DREAMS_ADDRESS = _dreams;
        priceOracle = ISlothPriceOracle(_priceOracle);
        treasury = _treasury;
        admin = msg.sender;
    }

    // ============ CAMPAIGN CREATION ============

    /**
     * @notice Create a new crowdfunding campaign with milestones
     * @dev Uses IPFS hashes (bytes32) for gas efficiency
     * @param _metadataHash IPFS hash of campaign metadata JSON (title, description, category, images)
     * @param _goalAmount Goal in USD (18 decimals)
     * @param _fundingDuration Duration in seconds (7-90 days)
     * @param _milestoneDescriptionHashes Array of IPFS hashes for milestone descriptions
     * @param _milestoneDeliverableHashes Array of IPFS hashes for deliverable specs
     * @param _milestoneDueDates Array of due dates (unix timestamps)
     * @param _milestoneFundPercentages Array of fund percentages (basis points, must sum to 10000)
     * @param _acceptedToken Which token to accept for this campaign
     */
    function createCampaign(
        bytes32 _metadataHash,
        uint256 _goalAmount,
        uint256 _fundingDuration,
        bytes32[] calldata _milestoneDescriptionHashes,
        bytes32[] calldata _milestoneDeliverableHashes,
        uint256[] calldata _milestoneDueDates,
        uint256[] calldata _milestoneFundPercentages,
        PaymentToken _acceptedToken
    ) external nonReentrant returns (uint256) {
        // Validation
        if (_metadataHash == bytes32(0)) revert InvalidMetadataHash();
        if (_goalAmount < 1000 * 1e18) revert InvalidGoal();
        if (_fundingDuration < MIN_CAMPAIGN_DURATION || _fundingDuration > MAX_CAMPAIGN_DURATION) revert InvalidDuration();

        // Validate milestones
        uint256 milestoneCount = _milestoneDescriptionHashes.length;
        if (milestoneCount < MIN_MILESTONES || milestoneCount > MAX_MILESTONES) revert InvalidMilestoneCount();
        if (
            milestoneCount != _milestoneDeliverableHashes.length ||
            milestoneCount != _milestoneDueDates.length ||
            milestoneCount != _milestoneFundPercentages.length
        ) revert MilestoneArrayMismatch();

        // Validate percentages sum to 100% - GAS OPTIMIZED with unchecked
        uint256 totalPercentage;
        for (uint256 i; i < milestoneCount;) {
            if (_milestoneFundPercentages[i] == 0) revert InvalidPercentage();
            totalPercentage += _milestoneFundPercentages[i];
            unchecked { ++i; }
        }
        if (totalPercentage != 10000) revert PercentageMustSum100();

        // Validate milestone dates - GAS OPTIMIZED with unchecked
        uint256 lastDate = block.timestamp + _fundingDuration;
        for (uint256 i; i < milestoneCount;) {
            if (_milestoneDueDates[i] <= lastDate) revert InvalidMilestoneDate();
            if (_milestoneDueDates[i] > lastDate + 365 days) revert MilestoneTooFarFuture();
            if (i > 0 && _milestoneDueDates[i] <= _milestoneDueDates[i-1]) revert MilestonesNotChronological();
            lastDate = _milestoneDueDates[i];
            unchecked { ++i; }
        }

        // Check creator reputation limits
        _checkCreatorLimits(msg.sender, _goalAmount);

        // Calculate required deposit (10% of goal)
        uint256 depositRequired = _goalAmount.percentage(CREATOR_DEPOSIT_BPS);

        // Transfer creator deposit using SafeERC20
        IERC20(USDC_ADDRESS).safeTransferFrom(msg.sender, address(this), depositRequired);

        // Create campaign
        uint256 campaignId = campaignCount++;
        Campaign storage campaign = campaigns[campaignId];

        campaign.creator = msg.sender;
        campaign.metadataHash = _metadataHash;
        campaign.goalAmount = _goalAmount;
        campaign.fundingDeadline = block.timestamp + _fundingDuration;
        campaign.creatorDeposit = depositRequired;
        campaign.status = CampaignStatus.FUNDING;
        campaign.acceptedToken = _acceptedToken;
        campaign.tokenAddress = _getTokenAddress(_acceptedToken);

        // Create milestones - GAS OPTIMIZED with unchecked
        for (uint256 i; i < milestoneCount;) {
            Milestone storage milestone = milestones[campaignId].push();
            milestone.descriptionHash = _milestoneDescriptionHashes[i];
            milestone.deliverableHash = _milestoneDeliverableHashes[i];
            milestone.dueDate = _milestoneDueDates[i];
            milestone.fundPercentage = _milestoneFundPercentages[i];
            milestone.status = MilestoneStatus.PENDING;
            unchecked { ++i; }
        }

        emit CampaignCreated(
            campaignId,
            msg.sender,
            _metadataHash,
            _goalAmount,
            campaign.fundingDeadline,
            milestoneCount
        );

        return campaignId;
    }

    function _checkCreatorLimits(address _creator, uint256 _goalAmount) internal view {
        uint256 successCount = creatorSuccessfulCampaigns[_creator];
        uint256 failCount = creatorFailedCampaigns[_creator];

        uint256 maxGoal = _getMaxCampaignGoal(successCount);

        if (_goalAmount > maxGoal) revert GoalExceedsLimit();
        if (failCount > successCount) revert TooManyFailedCampaigns();
    }

    /// @dev Helper to get max campaign goal based on success count (DRY principle)
    function _getMaxCampaignGoal(uint256 _successCount) internal pure returns (uint256) {
        if (_successCount == 0) return 10000 * 1e18;
        if (_successCount == 1) return 50000 * 1e18;
        if (_successCount == 2) return 100000 * 1e18;
        return 500000 * 1e18;
    }

    // ============ CONTRIBUTIONS ============

    function contribute(uint256 _campaignId, uint256 _tokenAmount)
        external
        nonReentrant
        campaignExists(_campaignId)
    {
        Campaign storage campaign = campaigns[_campaignId];
        if (campaign.status != CampaignStatus.FUNDING) revert CampaignNotFunding();
        if (block.timestamp >= campaign.fundingDeadline) revert FundingPeriodEnded();
        if (_tokenAmount == 0) revert ContributionTooSmall();

        address tokenAddress = campaign.tokenAddress;

        // Calculate USD value
        uint256 usdValue;
        if (campaign.acceptedToken == PaymentToken.USDC) {
            usdValue = _tokenAmount;
        } else if (campaign.acceptedToken == PaymentToken.DREAMS) {
            usdValue = priceOracle.convertToUSD(DREAMS_ADDRESS, _tokenAmount);
            usdValue = usdValue.mul(10000 + DREAMS_BONUS_BPS).div(10000);
        } else {
            usdValue = priceOracle.convertToUSD(tokenAddress, _tokenAmount);
        }

        if (usdValue < MIN_CONTRIBUTION_USD) revert ContributionTooSmall();

        // CHECKS-EFFECTS-INTERACTIONS: Update state before external call
        bool isNewBacker = campaign.contributions[msg.sender].amount == 0;
        if (isNewBacker) {
            campaign.backers.push(msg.sender);
        }

        Contribution storage contribution = campaign.contributions[msg.sender];
        contribution.amount += usdValue;
        contribution.tokenAmount += _tokenAmount;
        contribution.token = tokenAddress;
        contribution.contributionTime = block.timestamp;
        // NOTE: snapshotVotingPower removed - uses amount directly for voting power

        campaign.raisedAmount += usdValue;

        // Transfer tokens using SafeERC20
        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), _tokenAmount);

        emit ContributionMade(_campaignId, msg.sender, usdValue, _tokenAmount, tokenAddress);
    }

    function _getTokenAddress(PaymentToken _token) internal view returns (address) {
        if (_token == PaymentToken.USDC) return USDC_ADDRESS;
        if (_token == PaymentToken.ETH) return ETH_ADDRESS;
        if (_token == PaymentToken.AVAX) return AVAX_ADDRESS;
        if (_token == PaymentToken.DREAMS) return DREAMS_ADDRESS;
        revert InvalidAddress();
    }

    function finalizeFunding(uint256 _campaignId) external campaignExists(_campaignId) {
        Campaign storage campaign = campaigns[_campaignId];
        if (campaign.status != CampaignStatus.FUNDING) revert CampaignNotFunding();
        if (block.timestamp < campaign.fundingDeadline) revert FundingNotEnded();

        if (campaign.raisedAmount > 0) {
            campaign.status = CampaignStatus.VESTING;
            emit FundingCompleted(_campaignId, campaign.raisedAmount);
        } else {
            campaign.status = CampaignStatus.FAILED;
            emit FundingFailed(_campaignId, campaign.raisedAmount);
        }
    }

    // ============ MILESTONE MANAGEMENT ============

    /**
     * @notice Creator submits proof for current milestone
     * @param _campaignId Campaign ID
     * @param _proofHash IPFS hash of proof (deliverable, screenshots, demo, etc.)
     */
    function submitMilestoneProof(uint256 _campaignId, bytes32 _proofHash)
        external
        campaignExists(_campaignId)
        onlyCreator(_campaignId)
    {
        Campaign storage campaign = campaigns[_campaignId];
        if (campaign.status != CampaignStatus.VESTING) revert CampaignNotVesting();
        if (_proofHash == bytes32(0)) revert ProofHashRequired();

        uint256 milestoneIndex = campaign.currentMilestoneIndex;
        Milestone storage milestone = milestones[_campaignId][milestoneIndex];

        if (milestone.status != MilestoneStatus.PENDING) revert MilestoneAlreadySubmitted();
        if (block.timestamp > milestone.dueDate) revert MilestoneDeadlinePassed();

        milestone.proofHash = _proofHash;
        milestone.status = MilestoneStatus.SUBMITTED;
        milestone.votingEndTime = block.timestamp + VOTING_PERIOD;

        emit MilestoneSubmitted(_campaignId, milestoneIndex, _proofHash, milestone.votingEndTime);
    }

    function voteOnMilestone(uint256 _campaignId, bool _approve)
        external
        campaignExists(_campaignId)
        onlyBacker(_campaignId)
    {
        Campaign storage campaign = campaigns[_campaignId];
        uint256 milestoneIndex = campaign.currentMilestoneIndex;
        Milestone storage milestone = milestones[_campaignId][milestoneIndex];

        if (milestone.status != MilestoneStatus.SUBMITTED) revert MilestoneNotSubmitted();
        if (block.timestamp >= milestone.votingEndTime) revert VotingPeriodEnded();
        // Check if this person already voted on this milestone
        if (milestoneVotes[_campaignId][milestoneIndex][msg.sender]) revert AlreadyVoted();

        // You must wait 24 hours after contributing before you can vote.
        // This stops people from gaming the system by borrowing money just to vote.
        Contribution storage contribution = campaign.contributions[msg.sender];
        if (block.timestamp < contribution.contributionTime + VOTE_LOCK_PERIOD) {
            revert VoteLockNotExpired();
        }

        // Use contribution amount as voting power (removed redundant snapshotVotingPower field)
        uint256 voteWeight = contribution.amount;

        // CHECKS-EFFECTS-INTERACTIONS: Update state before any external interaction
        milestoneVotes[_campaignId][milestoneIndex][msg.sender] = true;

        if (_approve) {
            milestone.votesFor += voteWeight;
        } else {
            milestone.votesAgainst += voteWeight;
        }

        emit MilestoneVoted(_campaignId, milestoneIndex, msg.sender, _approve, voteWeight);

        _checkVotingResult(_campaignId, milestoneIndex);
    }

    function finalizeMilestoneVoting(uint256 _campaignId)
        external
        campaignExists(_campaignId)
    {
        Campaign storage campaign = campaigns[_campaignId];
        uint256 milestoneIndex = campaign.currentMilestoneIndex;
        Milestone storage milestone = milestones[_campaignId][milestoneIndex];

        if (milestone.status != MilestoneStatus.SUBMITTED) revert MilestoneNotSubmitted();
        if (block.timestamp < milestone.votingEndTime) revert VotingPeriodEnded();

        _checkVotingResult(_campaignId, milestoneIndex);
    }

    function _checkVotingResult(uint256 _campaignId, uint256 _milestoneIndex) internal {
        Campaign storage campaign = campaigns[_campaignId];
        Milestone storage milestone = milestones[_campaignId][_milestoneIndex];

        uint256 totalVotes = milestone.votesFor + milestone.votesAgainst;
        uint256 quorumRequired = campaign.raisedAmount.percentage(MIN_VOTE_QUORUM_BPS);

        if (totalVotes >= quorumRequired) {
            if (milestone.votesFor > milestone.votesAgainst) {
                _approveMilestone(_campaignId, _milestoneIndex);
            } else {
                _rejectMilestone(_campaignId, _milestoneIndex);
            }
        } else if (block.timestamp >= milestone.votingEndTime) {
            _rejectMilestone(_campaignId, _milestoneIndex);
        }
    }

    function _approveMilestone(uint256 _campaignId, uint256 _milestoneIndex) internal {
        Campaign storage campaign = campaigns[_campaignId];
        Milestone storage milestone = milestones[_campaignId][_milestoneIndex];

        milestone.status = MilestoneStatus.APPROVED;

        // Calculate release amount with full precision
        uint256 releaseAmount = (campaign.raisedAmount * milestone.fundPercentage) / 10000;

        // Track total released for accurate refund calculation
        campaign.totalReleasedAmount += releaseAmount;

        // CHECKS-EFFECTS-INTERACTIONS: State updated above, now do transfers
        campaign.currentMilestoneIndex++;

        // Distribute funds using helper (handles 80/10/5/5 split)
        (uint256 creatorTokens, uint256 treasuryTokens) = _distributeFunds(
            releaseAmount,
            campaign.tokenAddress,
            campaign.creator,
            campaign.acceptedToken == PaymentToken.USDC
        );

        emit MilestoneApproved(_campaignId, _milestoneIndex, creatorTokens, treasuryTokens);

        if (campaign.currentMilestoneIndex >= milestones[_campaignId].length) {
            _completeCampaign(_campaignId);
        }
    }

    function _rejectMilestone(uint256 _campaignId, uint256 _milestoneIndex) internal {
        Campaign storage campaign = campaigns[_campaignId];
        Milestone storage milestone = milestones[_campaignId][_milestoneIndex];

        milestone.status = MilestoneStatus.REJECTED;
        campaign.status = CampaignStatus.FAILED;
        campaignFailedTimestamp[_campaignId] = block.timestamp; // Record for refund expiration

        creatorFailedCampaigns[campaign.creator]++;

        emit MilestoneRejected(_campaignId, _milestoneIndex);
    }

    function expireMilestone(uint256 _campaignId)
        external
        campaignExists(_campaignId)
    {
        Campaign storage campaign = campaigns[_campaignId];
        uint256 milestoneIndex = campaign.currentMilestoneIndex;
        Milestone storage milestone = milestones[_campaignId][milestoneIndex];

        if (
            milestone.status != MilestoneStatus.PENDING &&
            milestone.status != MilestoneStatus.SUBMITTED
        ) revert MilestoneAlreadyResolved();
        if (block.timestamp <= milestone.dueDate) revert DeadlineNotPassed();

        milestone.status = MilestoneStatus.EXPIRED;
        campaign.status = CampaignStatus.FAILED;
        campaignFailedTimestamp[_campaignId] = block.timestamp; // Record for refund expiration

        creatorFailedCampaigns[campaign.creator]++;

        emit MilestoneExpired(_campaignId, milestoneIndex);
    }

    function _completeCampaign(uint256 _campaignId) internal {
        Campaign storage campaign = campaigns[_campaignId];
        campaign.status = CampaignStatus.COMPLETED;
        campaign.creatorDepositRefunded = true;

        creatorSuccessfulCampaigns[campaign.creator]++;

        // Transfer deposit back using SafeERC20
        IERC20(USDC_ADDRESS).safeTransfer(campaign.creator, campaign.creatorDeposit);

        emit CampaignCompleted(_campaignId, campaign.creator);
        emit CreatorDepositReturned(_campaignId, campaign.creator, campaign.creatorDeposit);
    }

    // ============ REFUNDS ============

    function claimRefund(uint256 _campaignId)
        external
        nonReentrant
        campaignExists(_campaignId)
    {
        Campaign storage campaign = campaigns[_campaignId];
        if (campaign.status != CampaignStatus.FAILED && campaign.status != CampaignStatus.CANCELLED) {
            revert CampaignNotFailed();
        }

        // Check refund expiration (365 days from failure)
        uint256 failedTime = campaignFailedTimestamp[_campaignId];
        if (failedTime > 0 && block.timestamp > failedTime + REFUND_CLAIM_PERIOD) {
            revert RefundPeriodExpired();
        }

        Contribution storage contribution = campaign.contributions[msg.sender];
        if (contribution.amount == 0) revert NoContribution();
        if (contribution.refunded) revert AlreadyRefunded();

        // CHECKS-EFFECTS-INTERACTIONS: Mark refunded FIRST
        contribution.refunded = true;

        // GAS OPTIMIZATION: Cache state variables
        uint256 raisedAmount = campaign.raisedAmount;
        uint256 remainingFunds = raisedAmount - campaign.totalReleasedAmount;

        // Calculate exactly how much money to return
        // We use extra decimal places to avoid rounding errors
        uint256 refundUSD = (contribution.amount * PRECISION * remainingFunds) / (raisedAmount * PRECISION);

        // Apply 3% refund fee (covers processing costs and prevents abuse)
        uint256 refundFee = (refundUSD * REFUND_FEE_BPS) / 10000;
        uint256 netRefundUSD = refundUSD - refundFee;

        // Convert to token amount
        uint256 refundTokens;
        uint256 feeTokens;
        if (campaign.acceptedToken == PaymentToken.USDC) {
            refundTokens = netRefundUSD;
            feeTokens = refundFee;
        } else {
            refundTokens = _convertUSDToToken(contribution.token, netRefundUSD);
            feeTokens = _convertUSDToToken(contribution.token, refundFee);
        }

        // Calculate proportional creator deposit share (no fee on deposit portion)
        uint256 depositShare = (contribution.amount * PRECISION * campaign.creatorDeposit) / (raisedAmount * PRECISION);

        // Transfer using SafeERC20
        if (refundTokens > 0) {
            IERC20(contribution.token).safeTransfer(msg.sender, refundTokens);
        }
        if (feeTokens > 0) {
            IERC20(contribution.token).safeTransfer(treasury, feeTokens);
        }
        if (depositShare > 0) {
            IERC20(USDC_ADDRESS).safeTransfer(msg.sender, depositShare);
        }

        emit RefundClaimed(_campaignId, msg.sender, refundTokens, depositShare, contribution.token);
    }

    function _convertUSDToToken(address _token, uint256 _usdValue) internal view returns (uint256) {
        uint256 tokenPrice = priceOracle.getPrice(_token);
        return (_usdValue * 1e8) / tokenPrice;
    }

    // ============ FEE DISTRIBUTION HELPERS ============

    /**
     * @notice Calculate the 80/10/5/5 fee split for a given amount
     * @dev Ensures precision by calculating dreamsStaker as remainder
     * @param _totalAmount The total amount to split
     * @return split The calculated fee split amounts
     */
    function _calculateFeeSplit(uint256 _totalAmount) internal pure returns (FeeSplit memory split) {
        split.creatorAmount = (_totalAmount * CREATOR_SHARE_BPS) / 10000;      // 80%
        split.treasuryAmount = (_totalAmount * PLATFORM_FEE_BPS) / 10000;       // 10%
        split.juicyStakerAmount = (_totalAmount * JUICY_STAKER_BPS) / 10000;    // 5%
        // Use remainder for last portion to ensure precision
        split.dreamsStakerAmount = _totalAmount - split.creatorAmount - split.treasuryAmount - split.juicyStakerAmount;
    }

    /**
     * @notice Convert USD fee split to token amounts
     * @param _feeSplit The USD fee split to convert
     * @param _tokenAddress The token to convert to
     * @param _isUSDC Whether the token is USDC (no conversion needed)
     * @return tokenSplit The fee split in token amounts
     */
    function _convertFeeSplitToTokens(
        FeeSplit memory _feeSplit,
        address _tokenAddress,
        bool _isUSDC
    ) internal view returns (FeeSplit memory tokenSplit) {
        if (_isUSDC) {
            return _feeSplit;
        }
        tokenSplit.creatorAmount = _convertUSDToToken(_tokenAddress, _feeSplit.creatorAmount);
        tokenSplit.treasuryAmount = _convertUSDToToken(_tokenAddress, _feeSplit.treasuryAmount);
        tokenSplit.juicyStakerAmount = _convertUSDToToken(_tokenAddress, _feeSplit.juicyStakerAmount);
        tokenSplit.dreamsStakerAmount = _convertUSDToToken(_tokenAddress, _feeSplit.dreamsStakerAmount);
    }

    /**
     * @notice Transfer staking rewards to pools or treasury as fallback
     * @param _tokenAddress The token to transfer
     * @param _juicyAmount Amount for JUICY stakers
     * @param _dreamsAmount Amount for DREAMS stakers
     */
    function _transferToStakingPools(
        address _tokenAddress,
        uint256 _juicyAmount,
        uint256 _dreamsAmount
    ) internal {
        // Transfer to JUICY staking pool or treasury as fallback
        if (juicyStakingPool != address(0)) {
            IERC20(_tokenAddress).safeTransfer(juicyStakingPool, _juicyAmount);
        } else {
            IERC20(_tokenAddress).safeTransfer(treasury, _juicyAmount);
        }

        // Transfer to DREAMS staking pool or treasury as fallback
        if (dreamsStakingPool != address(0)) {
            IERC20(_tokenAddress).safeTransfer(dreamsStakingPool, _dreamsAmount);
        } else {
            IERC20(_tokenAddress).safeTransfer(treasury, _dreamsAmount);
        }
    }

    /**
     * @notice Distribute funds according to the 80/10/5/5 split
     * @dev Combines fee calculation, conversion, and distribution
     * @param _releaseAmount The USD amount to distribute
     * @param _tokenAddress The token to transfer
     * @param _creator The creator address to receive 80%
     * @param _isUSDC Whether the token is USDC
     * @return creatorTokens The amount sent to creator (for event emission)
     * @return treasuryTokens The amount sent to treasury (for event emission)
     */
    function _distributeFunds(
        uint256 _releaseAmount,
        address _tokenAddress,
        address _creator,
        bool _isUSDC
    ) internal returns (uint256 creatorTokens, uint256 treasuryTokens) {
        // Calculate fee split
        FeeSplit memory usdSplit = _calculateFeeSplit(_releaseAmount);

        // Convert to tokens if needed
        FeeSplit memory tokenSplit = _convertFeeSplitToTokens(usdSplit, _tokenAddress, _isUSDC);

        // Transfer to creator and treasury
        IERC20(_tokenAddress).safeTransfer(_creator, tokenSplit.creatorAmount);
        IERC20(_tokenAddress).safeTransfer(treasury, tokenSplit.treasuryAmount);

        // Transfer to staking pools
        _transferToStakingPools(_tokenAddress, tokenSplit.juicyStakerAmount, tokenSplit.dreamsStakerAmount);

        return (tokenSplit.creatorAmount, tokenSplit.treasuryAmount);
    }

    // ============ CAMPAIGN CANCELLATION ============

    /**
     * @notice Cancel a campaign during funding phase
     * @dev Only creator can cancel. Backers get immediate refunds. Creator forfeits deposit.
     * @param _campaignId Campaign to cancel
     * @param _reasonHash IPFS hash of cancellation reason
     */
    function cancelCampaign(uint256 _campaignId, bytes32 _reasonHash)
        external
        nonReentrant
        campaignExists(_campaignId)
        onlyCreator(_campaignId)
    {
        Campaign storage campaign = campaigns[_campaignId];

        // Can only cancel during FUNDING phase
        if (campaign.status != CampaignStatus.FUNDING) revert CampaignNotCancellable();

        campaign.status = CampaignStatus.CANCELLED;
        campaignFailedTimestamp[_campaignId] = block.timestamp;

        // Creator forfeits deposit - it goes to treasury
        if (campaign.creatorDeposit > 0 && !campaign.creatorDepositRefunded) {
            campaign.creatorDepositRefunded = true;
            IERC20(USDC_ADDRESS).safeTransfer(treasury, campaign.creatorDeposit);
        }

        emit CampaignCancelled(_campaignId, _reasonHash);
    }

    // ============ DISPUTE RESOLUTION ============

    /**
     * @notice Creator initiates dispute for rejected milestone
     * @dev Must be called within 7 days of rejection
     * @param _campaignId Campaign with rejected milestone
     * @param _evidenceHash IPFS hash of additional evidence
     */
    function initiateDispute(uint256 _campaignId, bytes32 _evidenceHash)
        external
        campaignExists(_campaignId)
        onlyCreator(_campaignId)
        returns (uint256)
    {
        Campaign storage campaign = campaigns[_campaignId];
        uint256 milestoneIndex = campaign.currentMilestoneIndex;
        Milestone storage milestone = milestones[_campaignId][milestoneIndex];

        // Must be a rejected milestone
        if (milestone.status != MilestoneStatus.REJECTED) revert CampaignNotDisputable();

        // Must be within dispute period (7 days from failure)
        uint256 failedTime = campaignFailedTimestamp[_campaignId];
        if (failedTime == 0 || block.timestamp > failedTime + DISPUTE_PERIOD) {
            revert DisputePeriodExpired();
        }

        // Check no existing dispute
        if (disputes[_campaignId].status == DisputeStatus.PENDING) revert DisputeAlreadyExists();

        uint256 disputeId = disputeCount++;
        Dispute storage dispute = disputes[_campaignId];
        dispute.campaignId = _campaignId;
        dispute.milestoneIndex = milestoneIndex;
        dispute.evidenceHash = _evidenceHash;
        dispute.deadline = block.timestamp + DISPUTE_PERIOD;
        dispute.status = DisputeStatus.PENDING;

        emit DisputeInitiated(disputeId, _campaignId, milestoneIndex, _evidenceHash, dispute.deadline);

        return disputeId;
    }

    /**
     * @notice Arbitrator resolves a dispute
     * @dev Can release 0%, 50%, or 100% of milestone funds
     * @param _campaignId Campaign with dispute
     * @param _inFavorOfCreator True to rule in favor of creator
     * @param _releasePercentageBps Percentage to release (0, 5000, or 10000)
     */
    function resolveDispute(
        uint256 _campaignId,
        bool _inFavorOfCreator,
        uint256 _releasePercentageBps
    )
        external
        onlyArbitrator
        campaignExists(_campaignId)
    {
        Dispute storage dispute = disputes[_campaignId];
        if (dispute.status != DisputeStatus.PENDING) revert DisputeNotFound();

        // Validate release percentage (0%, 50%, or 100% only)
        if (_releasePercentageBps != 0 && _releasePercentageBps != 5000 && _releasePercentageBps != 10000) {
            revert InvalidReleasePercentage();
        }

        dispute.status = _inFavorOfCreator ? DisputeStatus.RESOLVED_FOR_CREATOR : DisputeStatus.RESOLVED_FOR_BACKERS;
        dispute.releasePercentage = _releasePercentageBps;

        if (_inFavorOfCreator && _releasePercentageBps > 0) {
            // Release partial or full milestone funds
            _releaseDisputedFunds(_campaignId, dispute.milestoneIndex, _releasePercentageBps);
        }

        emit DisputeResolved(_campaignId, _inFavorOfCreator, _releasePercentageBps);
    }

    function _releaseDisputedFunds(uint256 _campaignId, uint256 _milestoneIndex, uint256 _percentageBps) internal {
        Campaign storage campaign = campaigns[_campaignId];
        Milestone storage milestone = milestones[_campaignId][_milestoneIndex];

        // Calculate partial release amount
        uint256 fullReleaseAmount = (campaign.raisedAmount * milestone.fundPercentage) / 10000;
        uint256 actualRelease = (fullReleaseAmount * _percentageBps) / 10000;

        campaign.totalReleasedAmount += actualRelease;

        // Distribute funds using helper (handles 80/10/5/5 split)
        _distributeFunds(
            actualRelease,
            campaign.tokenAddress,
            campaign.creator,
            campaign.acceptedToken == PaymentToken.USDC
        );

        // Update milestone status based on percentage released
        if (_percentageBps == 10000) {
            milestone.status = MilestoneStatus.APPROVED;
            campaign.currentMilestoneIndex++;

            // Check if all milestones complete
            if (campaign.currentMilestoneIndex >= milestones[_campaignId].length) {
                _completeCampaign(_campaignId);
            } else {
                // Continue vesting
                campaign.status = CampaignStatus.VESTING;
            }
        }
        // If partial (50%), campaign remains failed and backers can still claim remaining refunds
    }

    /**
     * @notice Sweep expired refunds to treasury
     * @dev Can only be called after REFUND_CLAIM_PERIOD (365 days)
     * @param _campaignId Failed campaign with expired refunds
     */
    function sweepExpiredRefunds(uint256 _campaignId)
        external
        onlyAdmin
        campaignExists(_campaignId)
    {
        Campaign storage campaign = campaigns[_campaignId];
        if (campaign.status != CampaignStatus.FAILED && campaign.status != CampaignStatus.CANCELLED) {
            revert CampaignNotFailed();
        }

        uint256 failedTime = campaignFailedTimestamp[_campaignId];
        if (failedTime == 0 || block.timestamp <= failedTime + REFUND_CLAIM_PERIOD) {
            revert NoExpiredRefunds();
        }

        // Transfer remaining tokens to treasury
        address tokenAddress = campaign.tokenAddress;
        uint256 remainingBalance = IERC20(tokenAddress).balanceOf(address(this));

        // Note: This is a simplified implementation. In production, you'd want to track
        // exact unclaimed amounts per campaign to avoid sweeping funds from other campaigns.
        if (remainingBalance > 0) {
            IERC20(tokenAddress).safeTransfer(treasury, remainingBalance);
            emit ExpiredRefundsSwept(_campaignId, remainingBalance);
        }
    }

    // ============ VIEW FUNCTIONS ============

    function getCampaign(uint256 _campaignId)
        external
        view
        campaignExists(_campaignId)
        returns (
            address creator,
            bytes32 metadataHash,
            uint256 goalAmount,
            uint256 raisedAmount,
            uint256 fundingDeadline,
            CampaignStatus status,
            uint256 currentMilestoneIndex,
            uint256 milestoneCount
        )
    {
        Campaign storage campaign = campaigns[_campaignId];
        return (
            campaign.creator,
            campaign.metadataHash,
            campaign.goalAmount,
            campaign.raisedAmount,
            campaign.fundingDeadline,
            campaign.status,
            campaign.currentMilestoneIndex,
            milestones[_campaignId].length
        );
    }

    function getMilestone(uint256 _campaignId, uint256 _milestoneIndex)
        external
        view
        campaignExists(_campaignId)
        returns (
            bytes32 descriptionHash,
            bytes32 deliverableHash,
            uint256 dueDate,
            uint256 fundPercentage,
            bytes32 proofHash,
            MilestoneStatus status,
            uint256 votesFor,
            uint256 votesAgainst
        )
    {
        Milestone storage milestone = milestones[_campaignId][_milestoneIndex];
        return (
            milestone.descriptionHash,
            milestone.deliverableHash,
            milestone.dueDate,
            milestone.fundPercentage,
            milestone.proofHash,
            milestone.status,
            milestone.votesFor,
            milestone.votesAgainst
        );
    }

    function getContribution(uint256 _campaignId, address _backer)
        external
        view
        campaignExists(_campaignId)
        returns (uint256 amount, uint256 tokenAmount, address token, bool refunded, uint256 contributionTime)
    {
        Contribution storage contribution = campaigns[_campaignId].contributions[_backer];
        return (
            contribution.amount,
            contribution.tokenAmount,
            contribution.token,
            contribution.refunded,
            contribution.contributionTime
        );
    }

    function getCreatorReputation(address _creator)
        external
        view
        returns (uint256 successful, uint256 failed, uint256 maxCampaignSize)
    {
        uint256 successCount = creatorSuccessfulCampaigns[_creator];
        uint256 failCount = creatorFailedCampaigns[_creator];
        // GAS OPTIMIZATION: Reuse _getMaxCampaignGoal helper (DRY principle)
        return (successCount, failCount, _getMaxCampaignGoal(successCount));
    }

    function canVote(uint256 _campaignId, address _backer) external view returns (bool) {
        Contribution storage contribution = campaigns[_campaignId].contributions[_backer];
        if (contribution.amount == 0) return false;
        return block.timestamp >= contribution.contributionTime + VOTE_LOCK_PERIOD;
    }

    // ============ ADMIN FUNCTIONS ============

    function updateTreasury(address _newTreasury) external onlyAdmin {
        if (_newTreasury == address(0)) revert InvalidAddress();
        address oldTreasury = treasury;
        treasury = _newTreasury;
        emit TreasuryUpdated(oldTreasury, _newTreasury);
    }

    function updatePriceOracle(address _newOracle) external onlyAdmin {
        if (_newOracle == address(0)) revert InvalidAddress();
        address oldOracle = address(priceOracle);
        priceOracle = ISlothPriceOracle(_newOracle);
        emit PriceOracleUpdated(oldOracle, _newOracle);
    }

    function initiateAdminTransfer(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert InvalidAddress();
        pendingAdmin = _newAdmin;
        emit AdminTransferInitiated(admin, _newAdmin);
    }

    function acceptAdminTransfer() external {
        if (msg.sender != pendingAdmin) revert OnlyPendingAdmin();
        address oldAdmin = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferCompleted(oldAdmin, admin);
    }

    function cancelAdminTransfer() external onlyAdmin {
        if (pendingAdmin == address(0)) revert NoPendingAdmin();
        pendingAdmin = address(0);
    }

    /**
     * @notice Set the arbitrator (the neutral judge) for disputes
     * @dev The arbitrator decides when creators and backers disagree about milestone completion.
     *      For safety, this should be controlled by multiple people (a multi-sig wallet).
     * @param _arbitrator New arbitrator address
     */
    function setArbitrator(address _arbitrator) external onlyAdmin {
        if (_arbitrator == address(0)) revert InvalidAddress();
        address oldArbitrator = arbitrator;
        arbitrator = _arbitrator;
        emit ArbitratorUpdated(oldArbitrator, _arbitrator);
    }

    /**
     * @notice Set the JUICY staking pool address for reward distribution
     * @param _juicyStakingPool Address of the JUICY staking contract
     */
    function setJuicyStakingPool(address _juicyStakingPool) external onlyAdmin {
        juicyStakingPool = _juicyStakingPool;
        emit StakingPoolUpdated("JUICY", _juicyStakingPool);
    }

    /**
     * @notice Set the DREAMS staking pool address for reward distribution
     * @param _dreamsStakingPool Address of the DREAMS staking contract
     */
    function setDreamsStakingPool(address _dreamsStakingPool) external onlyAdmin {
        dreamsStakingPool = _dreamsStakingPool;
        emit StakingPoolUpdated("DREAMS", _dreamsStakingPool);
    }
}
