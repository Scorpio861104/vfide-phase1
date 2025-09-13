// SPDX-License-Identifier: MIT
pragma solidity 0.8.2;

/**
 * @title Sanctum Fund - ENHANCED COMMUNITY & CHARITY SYSTEM
 * @dev DAO-governed charitable giving with transparency and impact tracking
 * @notice Sacred fund for community good and charitable purposes
 */

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IProofLedger {
    function logActivity(address user, string calldata actionType, uint256 amount) external;
    function getProofScore(address user) external view returns (uint256,uint256,uint256,uint256,uint256);
    function updateTrustMetrics(address user, uint256 newScore, string calldata reason) external;
}

interface IDAO {
    function getVotingWeight(address user) external view returns (uint256);
    function propose(
        uint8 proposalType,
        string calldata title,
        string calldata description,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas
    ) external returns (uint256 proposalId);
}

interface IMultiSigDeveloperControl {
    function isApproved(bytes32 actionHash) external view returns (bool);
}

contract SanctumFund is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    /* ================================ CONSTANTS ================================ */
    
    uint256 public constant MIN_CHARITY_VERIFICATION_SCORE = 600; // Min trust for verification
    uint256 public constant MIN_DONATION_AMOUNT = 1e18;          // 1 VFIDE minimum
    uint256 public constant MAX_SINGLE_DISTRIBUTION = 100000e18; // 100k VFIDE max single
    uint256 public constant CHARITY_VERIFICATION_PERIOD = 90 days; // Re-verification period
    uint256 public constant IMPACT_REPORTING_PERIOD = 30 days;   // Impact report frequency
    uint256 public constant TRANSPARENCY_THRESHOLD = 1000e18;    // Min for transparency req
    
    /* ================================ ENUMS ================================ */
    
    enum CharityStatus {
        PENDING,        // Awaiting verification
        VERIFIED,       // Approved and active
        SUSPENDED,      // Temporarily suspended
        REJECTED,       // Rejected by DAO
        UNDER_REVIEW    // Under investigation
    }
    
    enum DonationType {
        COMMUNITY_BURN,     // Tokens burned for deflationary effect
        CHARITY_DONATION,   // Direct donation to verified charity
        DEVELOPMENT_FUND,   // Development funding
        EMERGENCY_RELIEF,   // Emergency disaster relief
        EDUCATION_FUND,     // Educational initiatives
        ENVIRONMENTAL,      // Environmental causes
        COMMUNITY_PROJECT   // Community-driven projects
    }
    
    enum FundingPriority {
        LOW,
        MEDIUM,
        HIGH,
        CRITICAL
    }
    
    /* ================================ STRUCTS ================================ */
    
    struct Charity {
        address charityAddress;
        string name;
        string description;
        string website;
        string verificationDocument;
        bytes32 documentHash;
        CharityStatus status;
        uint256 verifiedAt;
        uint256 lastVerification;
        uint256 totalReceived;
        uint256 totalDonations;
        uint256 impactScore;
        address verifier;
        string[] categories;
        mapping(address => uint256) donorContributions;
        mapping(uint256 => string) impactReports;
        uint256 impactReportCount;
    }
    
    struct Donation {
        uint256 id;
        address donor;
        address charity;
        uint256 amount;
        DonationType donationType;
        uint256 timestamp;
        string message;
        bytes32 txHash;
        bool anonymous;
        uint256 trustReward;
    }
    
    struct CommunityProposal {
        uint256 id;
        address proposer;
        string title;
        string description;
        uint256 requestedAmount;
        FundingPriority priority;
        address beneficiary;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 deadline;
        bool funded;
        bool executed;
        string deliverable;
        uint256 milestoneCount;
        mapping(uint256 => Milestone) milestones;
    }
    
    struct Milestone {
        string description;
        uint256 amount;
        bool completed;
        string proof;
        uint256 completedAt;
    }
    
    struct FundMetrics {
        uint256 totalDonated;
        uint256 totalBurned;
        uint256 totalCharities;
        uint256 totalDonors;
        uint256 averageDonation;
        uint256 lastDistribution;
        uint256 emergencyReserve;
    }
    
    struct DonorProfile {
        uint256 totalDonated;
        uint256 donationCount;
        uint256 firstDonation;
        uint256 lastDonation;
        uint256 charitiesSupported;
        uint256 trustBonus;
        bool isVerifiedDonor;
        DonationType[] donationTypes;
        mapping(address => uint256) charityDonations;
    }
    
    /* ================================ STATE VARIABLES ================================ */
    
    // Core fund management
    IERC20 public vfideToken;
    uint256 public fundBalance;
    uint256 public reserveBalance;
    uint256 public emergencyReserve;
    
    // Charity management
    mapping(address => Charity) public charities;
    mapping(bytes32 => address) public charityByHash;
    address[] public verifiedCharities;
    address[] public pendingCharities;
    
    // Donation tracking
    mapping(uint256 => Donation) public donations;
    mapping(address => DonorProfile) public donorProfiles;
    mapping(address => uint256[]) public userDonations;
    uint256 public nextDonationId = 1;
    
    // Community proposals
    mapping(uint256 => CommunityProposal) public communityProposals;
    mapping(address => uint256[]) public userProposals;
    uint256 public nextProposalId = 1;
    
    // Fund metrics and tracking
    FundMetrics public metrics;
    mapping(DonationType => uint256) public donationsByType;
    mapping(string => uint256) public donationsByCategory;
    
    // Fee and penalty deposits
    mapping(address => uint256) public penaltyDeposits;
    mapping(address => uint256) public feeDeposits;
    uint256 public totalPenalties;
    uint256 public totalFees;
    
    // Governance and verification
    mapping(address => bool) public authorizedVerifiers;
    mapping(address => uint256) public verifierReputation;
    mapping(bytes32 => bool) public approvedDistributions;
    
    // Emergency controls
    bool public emergencyWithdrawalsEnabled;
    uint256 public emergencyActivatedAt;
    mapping(address => bool) public emergencyRecipients;
    
    // Integration contracts
    IProofLedger public proofLedger;
    IDAO public dao;
    IMultiSigDeveloperControl public multiSigControl;
    
    /* ================================ EVENTS ================================ */
    
    // Donation events
    event DonationReceived(
        uint256 indexed donationId,
        address indexed donor,
        address indexed charity,
        uint256 amount,
        DonationType donationType
    );
    event CommunityBurnExecuted(uint256 amount, address indexed burner, string reason);
    event TrustRewardAwarded(address indexed donor, uint256 amount, uint256 trustBonus);
    
    // Charity events
    event CharityRegistered(address indexed charity, string name, address indexed verifier);
    event CharityVerified(address indexed charity, address indexed verifier, uint256 score);
    event CharityStatusChanged(address indexed charity, CharityStatus oldStatus, CharityStatus newStatus);
    event ImpactReportSubmitted(address indexed charity, uint256 reportId, string report);
    
    // Fund management events
    event FundsDistributed(address indexed charity, uint256 amount, string purpose);
    event EmergencyDistribution(address indexed recipient, uint256 amount, string reason);
    event FeeDeposited(uint256 amount, address indexed source);
    event PenaltyDeposited(uint256 amount, address indexed violator, string reason);
    
    // Community proposal events
    event CommunityProposalCreated(uint256 indexed proposalId, address indexed proposer, uint256 amount);
    event CommunityProposalFunded(uint256 indexed proposalId, uint256 amount);
    event MilestoneCompleted(uint256 indexed proposalId, uint256 milestone, string proof);
    
    // Governance events
    event VerifierAdded(address indexed verifier, uint256 reputation);
    event VerifierRemoved(address indexed verifier, string reason);
    event EmergencyModeActivated(address indexed activator, string reason);
    event EmergencyModeDeactivated(address indexed deactivator);
    
    /* ================================ MODIFIERS ================================ */
    
    modifier onlyVerifier() {
        require(authorizedVerifiers[msg.sender] || msg.sender == owner(), "Only authorized verifiers");
        _;
    }
    
    modifier validCharity(address charity) {
        require(charity != address(0), "Invalid charity address");
        require(charities[charity].status == CharityStatus.VERIFIED, "Charity not verified");
        _;
    }
    
    modifier sufficientBalance(uint256 amount) {
        require(vfideToken.balanceOf(address(this)) >= amount, "Insufficient fund balance");
        _;
    }
    
    modifier onlyHighTrust() {
        if (address(proofLedger) != address(0)) {
            (uint256 trust, uint256 security,,,) = proofLedger.getProofScore(msg.sender);
            require(trust >= MIN_CHARITY_VERIFICATION_SCORE && security >= 300, "Insufficient trust score");
        }
        _;
    }
    
    /* ================================ CONSTRUCTOR ================================ */
    
    constructor() Ownable() {}
    
    /* ================================ DONATION FUNCTIONS ================================ */
    
    /**
     * @dev Make a donation to a verified charity
     */
    function donateToCharity(
        address charity,
        uint256 amount,
        string calldata message,
        bool anonymous
    ) external validCharity(charity) whenNotPaused nonReentrant returns (uint256 donationId) {
        require(amount >= MIN_DONATION_AMOUNT, "Donation too small");
        require(vfideToken.balanceOf(msg.sender) >= amount, "Insufficient balance");
        
        vfideToken.safeTransferFrom(msg.sender, address(this), amount);
        
        donationId = nextDonationId++;
        
        // Create donation record
        Donation storage donation = donations[donationId];
        donation.id = donationId;
        donation.donor = anonymous ? address(0) : msg.sender;
        donation.charity = charity;
        donation.amount = amount;
        donation.donationType = DonationType.CHARITY_DONATION;
        donation.timestamp = block.timestamp;
        donation.message = message;
        donation.anonymous = anonymous;
        
        // Update charity stats
        Charity storage charityData = charities[charity];
        charityData.totalReceived += amount;
        charityData.totalDonations++;
        if (!anonymous) {
            charityData.donorContributions[msg.sender] += amount;
        }
        
        // Update donor profile
        DonorProfile storage profile = donorProfiles[msg.sender];
        profile.totalDonated += amount;
        profile.donationCount++;
        profile.charityDonations[charity] += amount;
        if (profile.firstDonation == 0) {
            profile.firstDonation = block.timestamp;
        }
        profile.lastDonation = block.timestamp;
        
        // Track donation
        userDonations[msg.sender].push(donationId);
        donationsByType[DonationType.CHARITY_DONATION] += amount;
        
        // Calculate and award trust bonus
        uint256 trustReward = _calculateTrustReward(amount, charity);
        donation.trustReward = trustReward;
        
        // Update metrics
        metrics.totalDonated += amount;
        metrics.totalDonors = _updateUniqueDonorCount();
        metrics.averageDonation = metrics.totalDonated / nextDonationId;
        
        emit DonationReceived(donationId, anonymous ? address(0) : msg.sender, charity, amount, DonationType.CHARITY_DONATION);
        
        if (trustReward > 0) {
            emit TrustRewardAwarded(msg.sender, amount, trustReward);
        }
        
        // Log in ProofLedger
        if (address(proofLedger) != address(0)) {
            try proofLedger.logActivity(msg.sender, "charitable_donation", amount) {} catch {}
        }
        
        return donationId;
    }
    
    /**
     * @dev Execute community burn (deflationary donation)
     */
    function executeCommunityBurn(uint256 amount, string calldata reason) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        require(amount >= MIN_DONATION_AMOUNT, "Burn amount too small");
        require(vfideToken.balanceOf(msg.sender) >= amount, "Insufficient balance");
        
        // Transfer tokens to this contract first
        vfideToken.safeTransferFrom(msg.sender, address(this), amount);
        
        // Burn the tokens (assuming VFIDE token has burn function)
        try vfideToken.transfer(address(0), amount) {
            // Successful burn
        } catch {
            // If direct burn fails, keep in contract as "burned" reserve
            reserveBalance += amount;
        }
        
        uint256 donationId = nextDonationId++;
        
        // Create donation record
        Donation storage donation = donations[donationId];
        donation.id = donationId;
        donation.donor = msg.sender;
        donation.charity = address(0); // Burn has no recipient
        donation.amount = amount;
        donation.donationType = DonationType.COMMUNITY_BURN;
        donation.timestamp = block.timestamp;
        donation.message = reason;
        
        // Update donor profile
        DonorProfile storage profile = donorProfiles[msg.sender];
        profile.totalDonated += amount;
        profile.donationCount++;
        if (profile.firstDonation == 0) {
            profile.firstDonation = block.timestamp;
        }
        profile.lastDonation = block.timestamp;
        
        // Track burn
        userDonations[msg.sender].push(donationId);
        donationsByType[DonationType.COMMUNITY_BURN] += amount;
        metrics.totalBurned += amount;
        
        // Award significant trust bonus for burns
        uint256 trustReward = amount / 1e18 * 10; // 10 points per token burned
        donation.trustReward = trustReward;
        
        emit CommunityBurnExecuted(amount, msg.sender, reason);
        emit DonationReceived(donationId, msg.sender, address(0), amount, DonationType.COMMUNITY_BURN);
        emit TrustRewardAwarded(msg.sender, amount, trustReward);
        
        // Log in ProofLedger
        if (address(proofLedger) != address(0)) {
            try proofLedger.logActivity(msg.sender, "community_burn", amount) {} catch {}
            try proofLedger.updateTrustMetrics(msg.sender, trustReward, "community_burn") {} catch {}
        }
    }
    
    /**
     * @dev Calculate trust reward for donation
     */
    function _calculateTrustReward(uint256 amount, address charity) internal view returns (uint256) {
        uint256 baseReward = amount / 1e18 * 5; // 5 points per token donated
        
        // Bonus for first-time donors
        if (donorProfiles[msg.sender].donationCount == 0) {
            baseReward += 50; // First donation bonus
        }
        
        // Bonus for supporting new charities
        if (charities[charity].totalDonations < 10) {
            baseReward += 25; // New charity support bonus
        }
        
        // Bonus for large donations
        if (amount >= 10000e18) {
            baseReward += 100; // Large donation bonus
        }
        
        return baseReward;
    }
    
    /* ================================ CHARITY MANAGEMENT ================================ */
    
    /**
     * @dev Register a new charity for verification
     */
    function registerCharity(
        address charityAddress,
        string calldata name,
        string calldata description,
        string calldata website,
        string calldata verificationDocument,
        string[] calldata categories
    ) external onlyHighTrust whenNotPaused {
        require(charityAddress != address(0), "Invalid charity address");
        require(bytes(name).length > 0, "Name required");
        require(charities[charityAddress].charityAddress == address(0), "Charity already registered");
        
        bytes32 documentHash = keccak256(abi.encodePacked(verificationDocument));
        
        Charity storage charity = charities[charityAddress];
        charity.charityAddress = charityAddress;
        charity.name = name;
        charity.description = description;
        charity.website = website;
        charity.verificationDocument = verificationDocument;
        charity.documentHash = documentHash;
        charity.status = CharityStatus.PENDING;
        charity.verifiedAt = 0;
        charity.lastVerification = 0;
        charity.verifier = msg.sender;
        charity.categories = categories;
        
        pendingCharities.push(charityAddress);
        charityByHash[documentHash] = charityAddress;
        
        emit CharityRegistered(charityAddress, name, msg.sender);
        
        // Log in ProofLedger
        if (address(proofLedger) != address(0)) {
            try proofLedger.logActivity(msg.sender, "charity_registration", 1) {} catch {}
        }
    }
    
    /**
     * @dev Verify a pending charity
     */
    function verifyCharity(address charityAddress, uint256 impactScore) 
        external 
        onlyVerifier 
        whenNotPaused 
    {
        Charity storage charity = charities[charityAddress];
        require(charity.status == CharityStatus.PENDING, "Charity not pending verification");
        require(impactScore <= 1000, "Invalid impact score");
        
        charity.status = CharityStatus.VERIFIED;
        charity.verifiedAt = block.timestamp;
        charity.lastVerification = block.timestamp;
        charity.impactScore = impactScore;
        charity.verifier = msg.sender;
        
        // Move from pending to verified
        verifiedCharities.push(charityAddress);
        _removePendingCharity(charityAddress);
        
        // Update metrics
        metrics.totalCharities++;
        
        // Update verifier reputation
        verifierReputation[msg.sender] += 10;
        
        emit CharityVerified(charityAddress, msg.sender, impactScore);
        emit CharityStatusChanged(charityAddress, CharityStatus.PENDING, CharityStatus.VERIFIED);
        
        // Log in ProofLedger
        if (address(proofLedger) != address(0)) {
            try proofLedger.logActivity(msg.sender, "charity_verification", impactScore) {} catch {}
        }
    }
    
    /**
     * @dev Submit impact report for charity
     */
    function submitImpactReport(string calldata report) external whenNotPaused {
        require(charities[msg.sender].status == CharityStatus.VERIFIED, "Not a verified charity");
        require(bytes(report).length > 0, "Report cannot be empty");
        
        Charity storage charity = charities[msg.sender];
        uint256 reportId = charity.impactReportCount++;
        charity.impactReports[reportId] = report;
        
        // Award impact score bonus
        charity.impactScore += 10;
        if (charity.impactScore > 1000) charity.impactScore = 1000;
        
        emit ImpactReportSubmitted(msg.sender, reportId, report);
    }
    
    /**
     * @dev Update charity status
     */
    function updateCharityStatus(address charityAddress, CharityStatus newStatus, string calldata reason) 
        external 
        onlyVerifier 
    {
        Charity storage charity = charities[charityAddress];
        CharityStatus oldStatus = charity.status;
        charity.status = newStatus;
        
        if (newStatus == CharityStatus.SUSPENDED || newStatus == CharityStatus.REJECTED) {
            // Remove from verified list
            _removeVerifiedCharity(charityAddress);
        }
        
        emit CharityStatusChanged(charityAddress, oldStatus, newStatus);
        
        // Log in ProofLedger
        if (address(proofLedger) != address(0)) {
            try proofLedger.logActivity(msg.sender, "charity_status_update", uint256(newStatus)) {} catch {}
        }
    }
    
    /* ================================ FUND DISTRIBUTION ================================ */
    
    /**
     * @dev Distribute funds to verified charity
     */
    function distributeFunds(
        address charity,
        uint256 amount,
        string calldata purpose
    ) external onlyVerifier validCharity(charity) sufficientBalance(amount) whenNotPaused nonReentrant {
        require(amount <= MAX_SINGLE_DISTRIBUTION, "Amount exceeds single distribution limit");
        require(amount >= TRANSPARENCY_THRESHOLD || bytes(purpose).length > 0, "Purpose required for large distributions");
        
        // Check for multi-sig approval for large distributions
        if (amount >= MAX_SINGLE_DISTRIBUTION / 2) {
            if (address(multiSigControl) != address(0)) {
                bytes32 actionHash = keccak256(abi.encodePacked("distribute_funds", charity, amount));
                require(multiSigControl.isApproved(actionHash), "Multi-sig approval required");
            }
        }
        
        vfideToken.safeTransfer(charity, amount);
        
        // Update charity stats
        Charity storage charityData = charities[charity];
        charityData.totalReceived += amount;
        
        // Update fund metrics
        fundBalance -= amount;
        metrics.lastDistribution = block.timestamp;
        
        emit FundsDistributed(charity, amount, purpose);
        
        // Update verifier reputation
        verifierReputation[msg.sender] += 5;
        
        // Log in ProofLedger
        if (address(proofLedger) != address(0)) {
            try proofLedger.logActivity(msg.sender, "fund_distribution", amount) {} catch {}
        }
    }
    
    /**
     * @dev Emergency distribution for disasters/crises
     */
    function emergencyDistribution(
        address recipient,
        uint256 amount,
        string calldata reason
    ) external onlyOwner sufficientBalance(amount) {
        require(emergencyWithdrawalsEnabled, "Emergency withdrawals not enabled");
        require(emergencyRecipients[recipient], "Recipient not approved for emergency funds");
        require(amount <= emergencyReserve, "Amount exceeds emergency reserve");
        
        vfideToken.safeTransfer(recipient, amount);
        emergencyReserve -= amount;
        
        emit EmergencyDistribution(recipient, amount, reason);
    }
    
    /* ================================ COMMUNITY PROPOSALS ================================ */
    
    /**
     * @dev Create community funding proposal
     */
    function createCommunityProposal(
        string calldata title,
        string calldata description,
        uint256 requestedAmount,
        FundingPriority priority,
        address beneficiary,
        string calldata deliverable
    ) external onlyHighTrust whenNotPaused returns (uint256 proposalId) {
        require(requestedAmount >= MIN_DONATION_AMOUNT, "Requested amount too small");
        require(requestedAmount <= fundBalance / 10, "Requested amount too large");
        require(beneficiary != address(0), "Invalid beneficiary");
        
        proposalId = nextProposalId++;
        
        CommunityProposal storage proposal = communityProposals[proposalId];
        proposal.id = proposalId;
        proposal.proposer = msg.sender;
        proposal.title = title;
        proposal.description = description;
        proposal.requestedAmount = requestedAmount;
        proposal.priority = priority;
        proposal.beneficiary = beneficiary;
        proposal.deadline = block.timestamp + 30 days;
        proposal.deliverable = deliverable;
        
        userProposals[msg.sender].push(proposalId);
        
        emit CommunityProposalCreated(proposalId, msg.sender, requestedAmount);
        
        // Log in ProofLedger
        if (address(proofLedger) != address(0)) {
            try proofLedger.logActivity(msg.sender, "community_proposal", requestedAmount) {} catch {}
        }
        
        return proposalId;
    }
    
    /**
     * @dev Vote on community proposal
     */
    function voteCommunityProposal(uint256 proposalId, bool support) external onlyHighTrust whenNotPaused {
        CommunityProposal storage proposal = communityProposals[proposalId];
        require(proposal.id != 0, "Proposal does not exist");
        require(block.timestamp <= proposal.deadline, "Voting period ended");
        require(!proposal.funded && !proposal.executed, "Proposal already processed");
        
        // Get voting weight from DAO
        uint256 weight = 1;
        if (address(dao) != address(0)) {
            weight = dao.getVotingWeight(msg.sender);
        }
        
        if (support) {
            proposal.votesFor += weight;
        } else {
            proposal.votesAgainst += weight;
        }
        
        // Log in ProofLedger
        if (address(proofLedger) != address(0)) {
            try proofLedger.logActivity(msg.sender, "community_vote", weight) {} catch {}
        }
    }
    
    /**
     * @dev Execute approved community proposal
     */
    function executeCommunityProposal(uint256 proposalId) 
        external 
        onlyVerifier 
        sufficientBalance(communityProposals[proposalId].requestedAmount) 
        whenNotPaused 
        nonReentrant 
    {
        CommunityProposal storage proposal = communityProposals[proposalId];
        require(proposal.id != 0, "Proposal does not exist");
        require(proposal.votesFor > proposal.votesAgainst, "Proposal not approved");
        require(!proposal.funded && !proposal.executed, "Proposal already processed");
        require(block.timestamp > proposal.deadline, "Voting period not ended");
        
        proposal.funded = true;
        proposal.executed = true;
        
        vfideToken.safeTransfer(proposal.beneficiary, proposal.requestedAmount);
        fundBalance -= proposal.requestedAmount;
        
        emit CommunityProposalFunded(proposalId, proposal.requestedAmount);
    }
    
    /* ================================ FEE & PENALTY MANAGEMENT ================================ */
    
    /**
     * @dev Deposit fees from system operations
     */
    function depositFee(uint256 amount) external {
        require(amount > 0, "Amount must be positive");
        
        vfideToken.safeTransferFrom(msg.sender, address(this), amount);
        
        feeDeposits[msg.sender] += amount;
        totalFees += amount;
        fundBalance += amount;
        
        emit FeeDeposited(amount, msg.sender);
    }
    
    /**
     * @dev Deposit penalty from trust violations
     */
    function depositPenalty(uint256 amount, string calldata reason) external {
        require(amount > 0, "Amount must be positive");
        
        vfideToken.safeTransferFrom(msg.sender, address(this), amount);
        
        penaltyDeposits[msg.sender] += amount;
        totalPenalties += amount;
        fundBalance += amount;
        
        emit PenaltyDeposited(amount, msg.sender, reason);
    }
    
    /* ================================ UTILITY FUNCTIONS ================================ */
    
    /**
     * @dev Update unique donor count
     */
    function _updateUniqueDonorCount() internal view returns (uint256) {
        // This would need to be tracked more efficiently in production
        // For now, return a reasonable estimate
        return nextDonationId / 2; // Rough estimate
    }
    
    /**
     * @dev Remove charity from pending list
     */
    function _removePendingCharity(address charity) internal {
        for (uint256 i = 0; i < pendingCharities.length; i++) {
            if (pendingCharities[i] == charity) {
                pendingCharities[i] = pendingCharities[pendingCharities.length - 1];
                pendingCharities.pop();
                break;
            }
        }
    }
    
    /**
     * @dev Remove charity from verified list
     */
    function _removeVerifiedCharity(address charity) internal {
        for (uint256 i = 0; i < verifiedCharities.length; i++) {
            if (verifiedCharities[i] == charity) {
                verifiedCharities[i] = verifiedCharities[verifiedCharities.length - 1];
                verifiedCharities.pop();
                break;
            }
        }
    }
    
    /* ================================ VIEW FUNCTIONS ================================ */
    
    /**
     * @dev Get approved charities
     */
    function getApprovedCharities() external view returns (address[] memory) {
        return verifiedCharities;
    }
    
    /**
     * @dev Get charity details
     */
    function getCharityDetails(address charity) external view returns (
        string memory name,
        string memory description,
        CharityStatus status,
        uint256 totalReceived,
        uint256 totalDonations,
        uint256 impactScore,
        uint256 verifiedAt
    ) {
        Charity storage charityData = charities[charity];
        return (
            charityData.name,
            charityData.description,
            charityData.status,
            charityData.totalReceived,
            charityData.totalDonations,
            charityData.impactScore,
            charityData.verifiedAt
        );
    }
    
    /**
     * @dev Get donor profile
     */
    function getDonorProfile(address donor) external view returns (
        uint256 totalDonated,
        uint256 donationCount,
        uint256 charitiesSupported,
        uint256 firstDonation,
        uint256 lastDonation,
        bool isVerifiedDonor
    ) {
        DonorProfile storage profile = donorProfiles[donor];
        return (
            profile.totalDonated,
            profile.donationCount,
            profile.charitiesSupported,
            profile.firstDonation,
            profile.lastDonation,
            profile.isVerifiedDonor
        );
    }
    
    /**
     * @dev Get fund metrics
     */
    function getFundMetrics() external view returns (FundMetrics memory) {
        return metrics;
    }
    
    /**
     * @dev Get donation details
     */
    function getDonation(uint256 donationId) external view returns (
        address donor,
        address charity,
        uint256 amount,
        DonationType donationType,
        uint256 timestamp,
        string memory message,
        bool anonymous
    ) {
        Donation storage donation = donations[donationId];
        return (
            donation.donor,
            donation.charity,
            donation.amount,
            donation.donationType,
            donation.timestamp,
            donation.message,
            donation.anonymous
        );
    }
    
    /**
     * @dev Get user donations
     */
    function getUserDonations(address user) external view returns (uint256[] memory) {
        return userDonations[user];
    }
    
    /* ================================ ADMIN FUNCTIONS ================================ */
    
    /**
     * @dev Set integration contracts
     */
    function setContracts(
        address _vfideToken,
        address _proofLedger,
        address _dao,
        address _multiSigControl
    ) external onlyOwner {
        vfideToken = IERC20(_vfideToken);
        proofLedger = IProofLedger(_proofLedger);
        dao = IDAO(_dao);
        multiSigControl = IMultiSigDeveloperControl(_multiSigControl);
    }
    
    /**
     * @dev Add authorized verifier
     */
    function addVerifier(address verifier, uint256 initialReputation) external onlyOwner {
        require(verifier != address(0), "Invalid verifier address");
        authorizedVerifiers[verifier] = true;
        verifierReputation[verifier] = initialReputation;
        emit VerifierAdded(verifier, initialReputation);
    }
    
    /**
     * @dev Remove verifier
     */
    function removeVerifier(address verifier, string calldata reason) external onlyOwner {
        authorizedVerifiers[verifier] = false;
        verifierReputation[verifier] = 0;
        emit VerifierRemoved(verifier, reason);
    }
    
    /**
     * @dev Enable emergency withdrawals
     */
    function enableEmergencyWithdrawals(string calldata reason) external onlyOwner {
        emergencyWithdrawalsEnabled = true;
        emergencyActivatedAt = block.timestamp;
        emit EmergencyModeActivated(msg.sender, reason);
    }
    
    /**
     * @dev Disable emergency withdrawals
     */
    function disableEmergencyWithdrawals() external onlyOwner {
        emergencyWithdrawalsEnabled = false;
        emergencyActivatedAt = 0;
        emit EmergencyModeDeactivated(msg.sender);
    }
    
    /**
     * @dev Add emergency recipient
     */
    function addEmergencyRecipient(address recipient) external onlyOwner {
        emergencyRecipients[recipient] = true;
    }
    
    /**
     * @dev Set emergency reserve amount
     */
    function setEmergencyReserve(uint256 amount) external onlyOwner {
        require(amount <= fundBalance, "Amount exceeds fund balance");
        emergencyReserve = amount;
    }
    
    /**
     * @dev Emergency pause
     */
    function emergencyPause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Emergency unpause
     */
    function emergencyUnpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Update fund balance (sync with actual token balance)
     */
    function updateFundBalance() external onlyOwner {
        fundBalance = vfideToken.balanceOf(address(this));
    }
}