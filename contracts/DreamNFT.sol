// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title DreamNFT
 * @notice Digital collectibles for SlothLabs Dreams - each one is unique and proves you created it.
 *
 * WHAT IS A DREAM NFT?
 * When you create a "dream" on SlothLabs, you can mint it as an NFT. This gives you:
 * - Proof of creation (timestamped on the blockchain forever)
 * - The ability to sell or transfer your dream
 * - Royalties when your dream sells to new owners (for commercial licenses)
 *
 * IP PROTECTION TIERS (like insurance levels):
 * - Tier 0 (Free): Social sharing - just shows you made it
 * - Tier 1 ($2): Basic timestamp - proves when you created it
 * - Tier 2 ($5): Standard protection + 25% royalty on resales
 * - Tier 3 ($10): Premium - includes witness attestations
 * - Tier 4 ($50): Enterprise - legal review and patent preparation
 *
 * LICENSE TYPES (what others can do with your dream):
 * - All Rights Reserved: You keep all rights, others just own the NFT
 * - Commercial License: NFT holder can use it for business purposes
 * - Creative Commons: Anyone can use it if they give you credit
 *
 * DUPLICATE PREVENTION:
 * We create a unique "fingerprint" (hash) of each dream's content.
 * If someone tries to mint the same dream twice, it gets blocked.
 */
contract DreamNFT is ERC721, ERC721URIStorage, ERC721Enumerable, ERC2981, Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;

    // ===== STATE VARIABLES =====
    Counters.Counter private _tokenIds;

    // Each dream has a unique "fingerprint" - this maps fingerprints to token IDs
    // If someone tries to mint a duplicate, we can catch it here
    mapping(bytes32 => uint256) public contentHashToTokenId;

    // Mapping from token ID to content hash
    mapping(uint256 => bytes32) public tokenIdToContentHash;

    // Mapping from token ID to dream metadata
    mapping(uint256 => DreamMetadata) public dreamMetadata;

    // Authorized minters (backend wallet)
    mapping(address => bool) public authorizedMinters;

    // Mapping from token ID to IP protection data
    mapping(uint256 => IPProtectionData) public ipProtection;

    // ===== ENUMS =====
    // IP Protection levels - higher tiers cost more but provide stronger legal protection
    enum IPTier {
        Tier0_Social,        // Free - just shows you made it, good for sharing
        Tier1_Basic,         // $2 - timestamp on blockchain proves when you created it
        Tier2_Standard,      // $5 - adds 25% royalty on resales + enhanced metadata
        Tier3_Premium,       // $10 - includes witness attestations for stronger proof
        Tier4_Enterprise     // $50 - full legal review + patent application preparation
    }

    // What can others do with your dream after they buy it?
    enum LicenseType {
        AllRightsReserved,   // Buyer just owns the NFT, you keep all other rights
        CommercialLicense,   // Buyer can use your dream for business purposes
        CreativeCommons      // Anyone can use it as long as they credit you
    }

    // ===== STRUCTS =====
    struct DreamMetadata {
        string mongoId;        // MongoDB _id for cross-reference
        string title;          // Dream title
        string category;       // Dream category
        string realm;          // daydream or nightmare
        uint256 epochId;       // Epoch number
        address originalCreator; // First creator/owner
        uint256 mintedAt;      // Timestamp
        IPTier ipTier;         // IP protection tier
        LicenseType licenseType; // License type
    }

    struct IPProtectionData {
        IPTier tier;
        LicenseType licenseType;
        uint96 royaltyBasisPoints; // Royalty in basis points (2500 = 25%)
        uint256 timestamp;         // Block timestamp
        bytes32 contentHash;       // Content verification hash
        bool isIPProtected;        // Whether IP protection is active
    }

    // ===== EVENTS =====
    event DreamMinted(
        uint256 indexed tokenId,
        address indexed creator,
        bytes32 contentHash,
        string mongoId,
        string tokenURI,
        IPTier ipTier,
        LicenseType licenseType
    );

    event IPProtectionEnabled(
        uint256 indexed tokenId,
        IPTier tier,
        LicenseType licenseType,
        uint96 royaltyBasisPoints
    );

    event MinterAuthorized(address indexed minter);
    event MinterRevoked(address indexed minter);
    event DreamContentUpdated(uint256 indexed tokenId, string newTokenURI);

    // ===== ERRORS =====
    error DuplicateDream(uint256 existingTokenId);
    error UnauthorizedMinter();
    error InvalidContentHash();
    error TokenDoesNotExist();

    // ===== CONSTRUCTOR =====
    constructor() ERC721("SlothLabs Dream", "DREAM") {
        // Owner is automatically an authorized minter
        authorizedMinters[msg.sender] = true;
    }

    // ===== MODIFIERS =====
    modifier onlyAuthorizedMinter() {
        if (!authorizedMinters[msg.sender]) revert UnauthorizedMinter();
        _;
    }

    // ===== MINTING FUNCTIONS =====

    /**
     * @notice Mint a new Dream NFT with IP protection
     * @param to Address to mint the NFT to (dream creator)
     * @param contentHash Keccak256 hash of dream content (title + content + category)
     * @param tokenURI IPFS URI containing full metadata
     * @param metadata On-chain metadata struct
     * @return tokenId The newly minted token ID
     */
    function mintDream(
        address to,
        bytes32 contentHash,
        string memory tokenURI,
        DreamMetadata memory metadata
    ) external onlyAuthorizedMinter nonReentrant returns (uint256) {
        // Validate content hash
        if (contentHash == bytes32(0)) revert InvalidContentHash();

        // We create a unique "fingerprint" of each dream's content
        // If someone tries to mint the same dream twice, this check catches it
        uint256 existingTokenId = contentHashToTokenId[contentHash];
        if (existingTokenId != 0) {
            revert DuplicateDream(existingTokenId);
        }

        // Increment token ID counter
        _tokenIds.increment();
        uint256 newTokenId = _tokenIds.current();

        // Mint the NFT
        _safeMint(to, newTokenId);
        _setTokenURI(newTokenId, tokenURI);

        // Store metadata
        contentHashToTokenId[contentHash] = newTokenId;
        tokenIdToContentHash[newTokenId] = contentHash;
        dreamMetadata[newTokenId] = metadata;

        // Set up IP protection if tier > 0
        if (uint8(metadata.ipTier) > 0) {
            _enableIPProtection(newTokenId, metadata.ipTier, metadata.licenseType, contentHash, to);
        }

        emit DreamMinted(newTokenId, to, contentHash, metadata.mongoId, tokenURI, metadata.ipTier, metadata.licenseType);

        return newTokenId;
    }

    /**
     * @notice Set up IP protection and royalties for a dream
     * @dev Only commercial licenses at Tier 2 or higher get royalties (25%).
     *      This means creators get paid every time their dream sells to a new owner.
     * @param tokenId The token ID
     * @param tier IP protection tier
     * @param licenseType License type
     * @param contentHash Content hash for verification
     * @param creator Creator address (who receives royalties)
     */
    function _enableIPProtection(
        uint256 tokenId,
        IPTier tier,
        LicenseType licenseType,
        bytes32 contentHash,
        address creator
    ) internal {
        // Only commercial licenses at Tier 2+ get royalties
        // This means: if you allow commercial use AND have decent protection,
        // you get 25% of every future sale automatically
        uint96 royaltyBps = 0;
        if (licenseType == LicenseType.CommercialLicense && uint8(tier) >= 2) {
            royaltyBps = 2500; // 25% royalty for Tier 2+ commercial licenses
        }

        // Store IP protection data
        ipProtection[tokenId] = IPProtectionData({
            tier: tier,
            licenseType: licenseType,
            royaltyBasisPoints: royaltyBps,
            timestamp: block.timestamp,
            contentHash: contentHash,
            isIPProtected: true
        });

        // Set ERC-2981 royalty info
        if (royaltyBps > 0) {
            _setTokenRoyalty(tokenId, creator, royaltyBps);
        }

        emit IPProtectionEnabled(tokenId, tier, licenseType, royaltyBps);
    }

    /**
     * @notice Update dream metadata URI (e.g., when image is updated)
     * @param tokenId The token ID to update
     * @param newTokenURI New IPFS URI
     */
    function updateTokenURI(
        uint256 tokenId,
        string memory newTokenURI
    ) external onlyAuthorizedMinter {
        if (!_exists(tokenId)) revert TokenDoesNotExist();
        _setTokenURI(tokenId, newTokenURI);
        emit DreamContentUpdated(tokenId, newTokenURI);
    }

    // ===== VIEW FUNCTIONS =====

    /**
     * @notice Check if a dream with this content hash already exists
     * @param contentHash Hash to check
     * @return exists Whether it exists
     * @return tokenId The existing token ID (0 if doesn't exist)
     */
    function dreamExists(bytes32 contentHash) external view returns (bool exists, uint256 tokenId) {
        tokenId = contentHashToTokenId[contentHash];
        exists = tokenId != 0;
    }

    /**
     * @notice Get dream metadata for a token
     * @param tokenId The token ID
     * @return metadata The dream metadata struct
     */
    function getDreamMetadata(uint256 tokenId) external view returns (DreamMetadata memory) {
        if (!_exists(tokenId)) revert TokenDoesNotExist();
        return dreamMetadata[tokenId];
    }

    /**
     * @notice Get all token IDs owned by an address
     * @param owner The owner address
     * @return tokenIds Array of token IDs
     */
    function getDreamsByOwner(address owner) external view returns (uint256[] memory) {
        uint256 balance = balanceOf(owner);
        uint256[] memory tokenIds = new uint256[](balance);

        for (uint256 i = 0; i < balance; i++) {
            tokenIds[i] = tokenOfOwnerByIndex(owner, i);
        }

        return tokenIds;
    }

    /**
     * @notice Get total number of dreams minted
     */
    function totalDreams() external view returns (uint256) {
        return _tokenIds.current();
    }

    /**
     * @notice Get IP protection data for a token
     * @param tokenId The token ID
     * @return ipData The IP protection data struct
     */
    function getIPProtection(uint256 tokenId) external view returns (IPProtectionData memory) {
        if (!_exists(tokenId)) revert TokenDoesNotExist();
        return ipProtection[tokenId];
    }

    /**
     * @notice Check if a token has IP protection enabled
     * @param tokenId The token ID
     * @return protected Whether IP protection is active
     */
    function isIPProtected(uint256 tokenId) external view returns (bool) {
        if (!_exists(tokenId)) return false;
        return ipProtection[tokenId].isIPProtected;
    }

    // ===== ADMIN FUNCTIONS =====

    /**
     * @notice Authorize an address to mint dreams
     * @param minter Address to authorize
     */
    function authorizeMinter(address minter) external onlyOwner {
        authorizedMinters[minter] = true;
        emit MinterAuthorized(minter);
    }

    /**
     * @notice Revoke minting authorization
     * @param minter Address to revoke
     */
    function revokeMinter(address minter) external onlyOwner {
        authorizedMinters[minter] = false;
        emit MinterRevoked(minter);
    }

    // ===== REQUIRED OVERRIDES =====

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 batchSize
    ) internal override(ERC721, ERC721Enumerable) {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }

    function _burn(uint256 tokenId) internal override(ERC721, ERC721URIStorage) {
        super._burn(tokenId);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, ERC721URIStorage, ERC2981)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
