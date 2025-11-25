// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";

/**
 * @title DreamMarketplace
 * @notice A marketplace where people can buy and sell Dream NFTs (digital art/collectibles).
 *
 * THREE WAYS TO SELL:
 * 1. Fixed Price - Set your price, first buyer gets it
 * 2. Auction - Let buyers bid, highest bidder wins
 * 3. Accept Offers - Anyone can make you an offer, accept the best one
 *
 * ACCEPTED PAYMENTS:
 * - ETH (on Base chain) or AVAX (on Avalanche)
 * - DREAMS tokens
 * - JUICY tokens
 *
 * HOW THE MONEY IS SPLIT (Example: NFT sells for 100 ETH with 25% royalty):
 * - Original Creator: 25 ETH (royalty - they get paid every time it resells!)
 * - Platform Treasury: 2.5 ETH (2.5% platform fee)
 * - Seller: 72.5 ETH (what's left after fees)
 *
 * AUCTION RULES:
 * - Minimum bid must be 5% higher than current highest bid
 * - If someone bids in the final 10 minutes, auction extends by 10 more minutes
 *   (this prevents last-second sniping)
 * - You can only cancel an auction if no one has bid yet
 */
contract DreamMarketplace is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ STATE ============

    IERC721 public immutable dreamNFT;
    address public treasury;
    address public admin;
    address public pendingAdmin;

    // Supported payment tokens
    IERC20 public dreamsToken;
    IERC20 public juicyToken;

    // Platform fee: 2.5% = 250 basis points
    uint256 public constant PLATFORM_FEE_BPS = 250;
    uint256 public constant BPS_DENOMINATOR = 10000;

    // Auction configuration
    uint256 public constant MIN_AUCTION_DURATION = 1 hours;
    uint256 public constant MAX_AUCTION_DURATION = 30 days;
    uint256 public constant AUCTION_EXTENSION_TIME = 10 minutes;
    uint256 public constant MIN_BID_INCREMENT_BPS = 500; // 5% minimum bid increment

    // Offer configuration
    uint256 public constant MIN_OFFER_DURATION = 1 hours;
    uint256 public constant MAX_OFFER_DURATION = 30 days;

    bool public marketplaceEnabled = true;

    // ============ ENUMS ============

    enum PaymentToken {
        NATIVE,     // ETH on BASE, AVAX on Avalanche
        DREAMS,
        JUICY
    }

    enum ListingType {
        NONE,
        FIXED_PRICE,
        AUCTION
    }

    // ============ STRUCTS ============

    struct Listing {
        address seller;
        uint256 price;
        PaymentToken paymentToken;
        ListingType listingType;
        uint256 createdAt;
    }

    struct Auction {
        address seller;
        uint256 reservePrice;
        uint256 highestBid;
        address highestBidder;
        PaymentToken paymentToken;
        uint256 startTime;
        uint256 endTime;
        bool settled;
    }

    struct Offer {
        address buyer;
        uint256 amount;
        PaymentToken paymentToken;
        uint256 expiresAt;
        bool accepted;
        bool cancelled;
    }

    // ============ MAPPINGS ============

    // tokenId => Listing
    mapping(uint256 => Listing) public listings;

    // tokenId => Auction
    mapping(uint256 => Auction) public auctions;

    // tokenId => offerId => Offer
    mapping(uint256 => mapping(uint256 => Offer)) public offers;

    // tokenId => offer count
    mapping(uint256 => uint256) public offerCount;

    // ============ EVENTS ============

    event Listed(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 price,
        PaymentToken paymentToken
    );

    event ListingCancelled(uint256 indexed tokenId, address indexed seller);

    event Sale(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed buyer,
        uint256 price,
        uint256 royaltyAmount,
        uint256 platformFee,
        PaymentToken paymentToken
    );

    event AuctionCreated(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 reservePrice,
        PaymentToken paymentToken,
        uint256 startTime,
        uint256 endTime
    );

    event BidPlaced(
        uint256 indexed tokenId,
        address indexed bidder,
        uint256 amount,
        uint256 newEndTime
    );

    event AuctionSettled(
        uint256 indexed tokenId,
        address indexed winner,
        uint256 finalPrice,
        uint256 royaltyAmount,
        uint256 platformFee
    );

    event AuctionCancelled(uint256 indexed tokenId, address indexed seller);

    event OfferMade(
        uint256 indexed tokenId,
        uint256 indexed offerId,
        address indexed buyer,
        uint256 amount,
        PaymentToken paymentToken,
        uint256 expiresAt
    );

    event OfferAccepted(
        uint256 indexed tokenId,
        uint256 indexed offerId,
        address indexed seller,
        address buyer,
        uint256 amount
    );

    event OfferCancelled(uint256 indexed tokenId, uint256 indexed offerId);

    event MarketplaceToggled(bool enabled);
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event PaymentTokensUpdated(address dreams, address juicy);
    event AdminTransferInitiated(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferCompleted(address indexed oldAdmin, address indexed newAdmin);

    // ============ ERRORS ============

    error MarketplaceDisabled();
    error NotTokenOwner();
    error NotSeller();
    error NotAdmin();
    error NotPendingAdmin();
    error InvalidPrice();
    error InvalidDuration();
    error InvalidPaymentToken();
    error ListingNotFound();
    error AuctionNotFound();
    error AuctionNotEnded();
    error AuctionAlreadySettled();
    error AuctionStillActive();
    error BidTooLow();
    error CannotBidOnOwnAuction();
    error OfferNotFound();
    error OfferExpired();
    error OfferAlreadyAccepted();
    error OfferAlreadyCancelled();
    error NotOfferBuyer();
    error InsufficientPayment();
    error TransferFailed();
    error InvalidAddress();
    error TokenAlreadyListed();
    error AuctionActive();

    // ============ MODIFIERS ============

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier whenEnabled() {
        if (!marketplaceEnabled) revert MarketplaceDisabled();
        _;
    }

    // ============ CONSTRUCTOR ============

    constructor(
        address _dreamNFT,
        address _treasury,
        address _dreamsToken,
        address _juicyToken
    ) {
        if (_dreamNFT == address(0)) revert InvalidAddress();
        if (_treasury == address(0)) revert InvalidAddress();

        dreamNFT = IERC721(_dreamNFT);
        treasury = _treasury;
        admin = msg.sender;

        if (_dreamsToken != address(0)) {
            dreamsToken = IERC20(_dreamsToken);
        }
        if (_juicyToken != address(0)) {
            juicyToken = IERC20(_juicyToken);
        }
    }

    // ============ FIXED PRICE LISTINGS ============

    /**
     * @notice List an NFT for sale at a fixed price
     * @param tokenId The token ID to list
     * @param price The sale price
     * @param paymentToken The payment token type
     */
    function listForSale(
        uint256 tokenId,
        uint256 price,
        PaymentToken paymentToken
    ) external whenEnabled nonReentrant {
        if (dreamNFT.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (price == 0) revert InvalidPrice();
        if (listings[tokenId].listingType != ListingType.NONE) revert TokenAlreadyListed();
        if (auctions[tokenId].endTime > block.timestamp) revert AuctionActive();
        _validatePaymentToken(paymentToken);

        // The NFT is held by the marketplace for safekeeping until the sale completes
        dreamNFT.transferFrom(msg.sender, address(this), tokenId);

        listings[tokenId] = Listing({
            seller: msg.sender,
            price: price,
            paymentToken: paymentToken,
            listingType: ListingType.FIXED_PRICE,
            createdAt: block.timestamp
        });

        emit Listed(tokenId, msg.sender, price, paymentToken);
    }

    /**
     * @notice Cancel a fixed price listing
     * @param tokenId The token ID to cancel
     */
    function cancelListing(uint256 tokenId) external nonReentrant {
        Listing storage listing = listings[tokenId];
        if (listing.listingType != ListingType.FIXED_PRICE) revert ListingNotFound();
        if (listing.seller != msg.sender) revert NotSeller();

        address seller = listing.seller;

        // Clear listing
        delete listings[tokenId];

        // Return NFT to seller
        dreamNFT.transferFrom(address(this), seller, tokenId);

        emit ListingCancelled(tokenId, seller);
    }

    /**
     * @notice Buy a listed NFT at the fixed price
     * @param tokenId The token ID to buy
     */
    function buyNow(uint256 tokenId) external payable whenEnabled nonReentrant {
        Listing storage listing = listings[tokenId];
        if (listing.listingType != ListingType.FIXED_PRICE) revert ListingNotFound();

        address seller = listing.seller;
        uint256 price = listing.price;
        PaymentToken paymentToken = listing.paymentToken;

        // Clear listing before transfers
        delete listings[tokenId];

        // Process payment and distribute funds
        _processPayment(tokenId, seller, msg.sender, price, paymentToken);

        // Transfer NFT to buyer
        dreamNFT.transferFrom(address(this), msg.sender, tokenId);
    }

    // ============ AUCTIONS ============

    /**
     * @notice Create an auction for an NFT
     * @param tokenId The token ID to auction
     * @param reservePrice The minimum price to accept
     * @param paymentToken The payment token type
     * @param duration The auction duration in seconds
     */
    function createAuction(
        uint256 tokenId,
        uint256 reservePrice,
        PaymentToken paymentToken,
        uint256 duration
    ) external whenEnabled nonReentrant {
        if (dreamNFT.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (reservePrice == 0) revert InvalidPrice();
        if (duration < MIN_AUCTION_DURATION || duration > MAX_AUCTION_DURATION) revert InvalidDuration();
        if (listings[tokenId].listingType != ListingType.NONE) revert TokenAlreadyListed();
        if (auctions[tokenId].endTime > block.timestamp && !auctions[tokenId].settled) revert AuctionActive();
        _validatePaymentToken(paymentToken);

        // The NFT is held by the marketplace for safekeeping until the sale completes
        dreamNFT.transferFrom(msg.sender, address(this), tokenId);

        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + duration;

        auctions[tokenId] = Auction({
            seller: msg.sender,
            reservePrice: reservePrice,
            highestBid: 0,
            highestBidder: address(0),
            paymentToken: paymentToken,
            startTime: startTime,
            endTime: endTime,
            settled: false
        });

        // Mark as auction listing
        listings[tokenId].listingType = ListingType.AUCTION;

        emit AuctionCreated(tokenId, msg.sender, reservePrice, paymentToken, startTime, endTime);
    }

    /**
     * @notice Place a bid on an auction
     * @param tokenId The token ID to bid on
     * @param bidAmount The bid amount (for ERC20 tokens)
     */
    function placeBid(uint256 tokenId, uint256 bidAmount) external payable whenEnabled nonReentrant {
        Auction storage auction = auctions[tokenId];
        if (auction.endTime == 0 || auction.settled) revert AuctionNotFound();
        if (block.timestamp >= auction.endTime) revert AuctionNotEnded();
        if (msg.sender == auction.seller) revert CannotBidOnOwnAuction();

        uint256 amount;
        if (auction.paymentToken == PaymentToken.NATIVE) {
            amount = msg.value;
        } else {
            amount = bidAmount;
        }

        // Must be at least reserve price
        if (amount < auction.reservePrice) revert BidTooLow();

        // Must be at least 5% higher than current highest bid
        if (auction.highestBid > 0) {
            uint256 minBid = auction.highestBid + (auction.highestBid * MIN_BID_INCREMENT_BPS / BPS_DENOMINATOR);
            if (amount < minBid) revert BidTooLow();
        }

        // Refund previous bidder
        if (auction.highestBidder != address(0)) {
            _refundBid(auction.highestBidder, auction.highestBid, auction.paymentToken);
        }

        // Collect new bid
        if (auction.paymentToken != PaymentToken.NATIVE) {
            IERC20 token = _getPaymentToken(auction.paymentToken);
            token.safeTransferFrom(msg.sender, address(this), amount);
        }

        auction.highestBid = amount;
        auction.highestBidder = msg.sender;

        // If someone bids in the final 10 minutes, extend the auction by 10 more minutes
        // This prevents "sniping" - last-second bids that others can't respond to
        uint256 newEndTime = auction.endTime;
        if (block.timestamp + AUCTION_EXTENSION_TIME > auction.endTime) {
            newEndTime = block.timestamp + AUCTION_EXTENSION_TIME;
            auction.endTime = newEndTime;
        }

        emit BidPlaced(tokenId, msg.sender, amount, newEndTime);
    }

    /**
     * @notice Settle a completed auction
     * @param tokenId The token ID of the auction
     */
    function settleAuction(uint256 tokenId) external nonReentrant {
        Auction storage auction = auctions[tokenId];
        if (auction.endTime == 0) revert AuctionNotFound();
        if (block.timestamp < auction.endTime) revert AuctionStillActive();
        if (auction.settled) revert AuctionAlreadySettled();

        auction.settled = true;

        // Clear listing type
        delete listings[tokenId];

        if (auction.highestBidder != address(0) && auction.highestBid >= auction.reservePrice) {
            // Auction successful - process payment and transfer NFT
            (uint256 royaltyAmount, uint256 platformFee) = _calculateFees(tokenId, auction.highestBid);

            _distributePayment(
                tokenId,
                auction.seller,
                auction.highestBid,
                royaltyAmount,
                platformFee,
                auction.paymentToken
            );

            dreamNFT.transferFrom(address(this), auction.highestBidder, tokenId);

            emit AuctionSettled(tokenId, auction.highestBidder, auction.highestBid, royaltyAmount, platformFee);
        } else {
            // Auction failed - return NFT to seller
            dreamNFT.transferFrom(address(this), auction.seller, tokenId);

            // Refund any bid (shouldn't happen if reserve not met, but safety)
            if (auction.highestBidder != address(0)) {
                _refundBid(auction.highestBidder, auction.highestBid, auction.paymentToken);
            }

            emit AuctionCancelled(tokenId, auction.seller);
        }
    }

    /**
     * @notice Cancel an auction with no bids
     * @param tokenId The token ID of the auction
     */
    function cancelAuction(uint256 tokenId) external nonReentrant {
        Auction storage auction = auctions[tokenId];
        if (auction.endTime == 0 || auction.settled) revert AuctionNotFound();
        if (auction.seller != msg.sender) revert NotSeller();
        if (auction.highestBidder != address(0)) revert AuctionActive(); // Can't cancel with bids

        auction.settled = true;
        delete listings[tokenId];

        // Return NFT to seller
        dreamNFT.transferFrom(address(this), auction.seller, tokenId);

        emit AuctionCancelled(tokenId, auction.seller);
    }

    // ============ OFFERS ============

    /**
     * @notice Make an offer on any NFT (even if not listed)
     * @param tokenId The token ID to make an offer on
     * @param amount The offer amount
     * @param paymentToken The payment token type
     * @param duration How long the offer is valid
     */
    function makeOffer(
        uint256 tokenId,
        uint256 amount,
        PaymentToken paymentToken,
        uint256 duration
    ) external payable whenEnabled nonReentrant {
        if (amount == 0) revert InvalidPrice();
        if (duration < MIN_OFFER_DURATION || duration > MAX_OFFER_DURATION) revert InvalidDuration();
        _validatePaymentToken(paymentToken);

        // Collect payment upfront
        if (paymentToken == PaymentToken.NATIVE) {
            if (msg.value != amount) revert InsufficientPayment();
        } else {
            IERC20 token = _getPaymentToken(paymentToken);
            token.safeTransferFrom(msg.sender, address(this), amount);
        }

        uint256 offerId = offerCount[tokenId];
        offerCount[tokenId]++;

        offers[tokenId][offerId] = Offer({
            buyer: msg.sender,
            amount: amount,
            paymentToken: paymentToken,
            expiresAt: block.timestamp + duration,
            accepted: false,
            cancelled: false
        });

        emit OfferMade(tokenId, offerId, msg.sender, amount, paymentToken, block.timestamp + duration);
    }

    /**
     * @notice Accept an offer (NFT owner only)
     * @param tokenId The token ID
     * @param offerId The offer ID to accept
     */
    function acceptOffer(uint256 tokenId, uint256 offerId) external whenEnabled nonReentrant {
        if (dreamNFT.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();

        Offer storage offer = offers[tokenId][offerId];
        if (offer.buyer == address(0)) revert OfferNotFound();
        if (offer.accepted) revert OfferAlreadyAccepted();
        if (offer.cancelled) revert OfferAlreadyCancelled();
        if (block.timestamp >= offer.expiresAt) revert OfferExpired();

        offer.accepted = true;

        // Cancel any active listing/auction
        if (listings[tokenId].listingType == ListingType.FIXED_PRICE) {
            delete listings[tokenId];
        }

        // Process payment (funds already in contract)
        (uint256 royaltyAmount, uint256 platformFee) = _calculateFees(tokenId, offer.amount);

        _distributePayment(
            tokenId,
            msg.sender,
            offer.amount,
            royaltyAmount,
            platformFee,
            offer.paymentToken
        );

        // Transfer NFT to buyer
        dreamNFT.transferFrom(msg.sender, offer.buyer, tokenId);

        emit OfferAccepted(tokenId, offerId, msg.sender, offer.buyer, offer.amount);
    }

    /**
     * @notice Cancel an offer and get refund
     * @param tokenId The token ID
     * @param offerId The offer ID to cancel
     */
    function cancelOffer(uint256 tokenId, uint256 offerId) external nonReentrant {
        Offer storage offer = offers[tokenId][offerId];
        if (offer.buyer == address(0)) revert OfferNotFound();
        if (offer.buyer != msg.sender) revert NotOfferBuyer();
        if (offer.accepted) revert OfferAlreadyAccepted();
        if (offer.cancelled) revert OfferAlreadyCancelled();

        offer.cancelled = true;

        // Refund the offer amount
        _refundBid(offer.buyer, offer.amount, offer.paymentToken);

        emit OfferCancelled(tokenId, offerId);
    }

    // ============ INTERNAL FUNCTIONS ============

    function _validatePaymentToken(PaymentToken paymentToken) internal view {
        if (paymentToken == PaymentToken.DREAMS && address(dreamsToken) == address(0)) {
            revert InvalidPaymentToken();
        }
        if (paymentToken == PaymentToken.JUICY && address(juicyToken) == address(0)) {
            revert InvalidPaymentToken();
        }
    }

    function _getPaymentToken(PaymentToken paymentToken) internal view returns (IERC20) {
        if (paymentToken == PaymentToken.DREAMS) {
            return dreamsToken;
        } else if (paymentToken == PaymentToken.JUICY) {
            return juicyToken;
        }
        revert InvalidPaymentToken();
    }

    function _processPayment(
        uint256 tokenId,
        address seller,
        address buyer,
        uint256 price,
        PaymentToken paymentToken
    ) internal {
        (uint256 royaltyAmount, uint256 platformFee) = _calculateFees(tokenId, price);

        if (paymentToken == PaymentToken.NATIVE) {
            if (msg.value < price) revert InsufficientPayment();

            _distributePayment(tokenId, seller, price, royaltyAmount, platformFee, paymentToken);

            // Refund excess
            if (msg.value > price) {
                (bool refunded, ) = buyer.call{value: msg.value - price}("");
                if (!refunded) revert TransferFailed();
            }
        } else {
            IERC20 token = _getPaymentToken(paymentToken);
            token.safeTransferFrom(buyer, address(this), price);
            _distributePayment(tokenId, seller, price, royaltyAmount, platformFee, paymentToken);
        }

        emit Sale(tokenId, seller, buyer, price, royaltyAmount, platformFee, paymentToken);
    }

    function _calculateFees(uint256 tokenId, uint256 price) internal view returns (uint256 royaltyAmount, uint256 platformFee) {
        // Platform fee: 2.5%
        platformFee = (price * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;

        // Check for ERC-2981 royalty
        try IERC2981(address(dreamNFT)).royaltyInfo(tokenId, price) returns (address, uint256 royalty) {
            royaltyAmount = royalty;
        } catch {
            royaltyAmount = 0;
        }

        return (royaltyAmount, platformFee);
    }

    /**
     * @notice Calculate fees and get royalty receiver in one call
     * @dev Optimized to avoid duplicate royaltyInfo calls
     * @param tokenId The token ID
     * @param price The sale price
     * @return royaltyReceiver The address to receive royalties
     * @return royaltyAmount The royalty amount
     * @return platformFee The platform fee amount
     */
    function _calculateFeesWithReceiver(uint256 tokenId, uint256 price)
        internal
        view
        returns (address royaltyReceiver, uint256 royaltyAmount, uint256 platformFee)
    {
        // Platform fee: 2.5%
        platformFee = (price * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;

        // Check for ERC-2981 royalty (single call for both receiver and amount)
        try IERC2981(address(dreamNFT)).royaltyInfo(tokenId, price) returns (address receiver, uint256 royalty) {
            royaltyReceiver = receiver;
            royaltyAmount = royalty;
        } catch {
            royaltyReceiver = address(0);
            royaltyAmount = 0;
        }
    }

    function _distributePayment(
        uint256 tokenId,
        address seller,
        uint256 price,
        uint256 royaltyAmount,
        uint256 platformFee,
        PaymentToken paymentToken
    ) internal {
        // Get royalty receiver (avoids duplicate royaltyInfo call in most code paths)
        address royaltyReceiver;
        if (royaltyAmount > 0) {
            (royaltyReceiver, ) = IERC2981(address(dreamNFT)).royaltyInfo(tokenId, price);
        }

        _distributePaymentWithReceiver(
            seller,
            price,
            royaltyReceiver,
            royaltyAmount,
            platformFee,
            paymentToken
        );
    }

    /**
     * @notice Distribute payment with pre-fetched royalty receiver
     * @dev Internal function to avoid duplicate royaltyInfo calls
     */
    function _distributePaymentWithReceiver(
        address seller,
        uint256 price,
        address royaltyReceiver,
        uint256 royaltyAmount,
        uint256 platformFee,
        PaymentToken paymentToken
    ) internal {
        uint256 sellerAmount = price - royaltyAmount - platformFee;

        if (paymentToken == PaymentToken.NATIVE) {
            // Pay royalty
            if (royaltyAmount > 0 && royaltyReceiver != address(0)) {
                (bool royaltyPaid, ) = royaltyReceiver.call{value: royaltyAmount}("");
                if (!royaltyPaid) revert TransferFailed();
            }

            // Pay platform fee
            (bool feePaid, ) = treasury.call{value: platformFee}("");
            if (!feePaid) revert TransferFailed();

            // Pay seller
            (bool sellerPaid, ) = seller.call{value: sellerAmount}("");
            if (!sellerPaid) revert TransferFailed();
        } else {
            IERC20 token = _getPaymentToken(paymentToken);

            // Pay royalty
            if (royaltyAmount > 0 && royaltyReceiver != address(0)) {
                token.safeTransfer(royaltyReceiver, royaltyAmount);
            }

            // Pay platform fee
            token.safeTransfer(treasury, platformFee);

            // Pay seller
            token.safeTransfer(seller, sellerAmount);
        }
    }

    function _refundBid(address bidder, uint256 amount, PaymentToken paymentToken) internal {
        if (paymentToken == PaymentToken.NATIVE) {
            (bool sent, ) = bidder.call{value: amount}("");
            if (!sent) revert TransferFailed();
        } else {
            IERC20 token = _getPaymentToken(paymentToken);
            token.safeTransfer(bidder, amount);
        }
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get listing details
     * @param tokenId The token ID
     */
    function getListing(uint256 tokenId) external view returns (Listing memory) {
        return listings[tokenId];
    }

    /**
     * @notice Get auction details
     * @param tokenId The token ID
     */
    function getAuction(uint256 tokenId) external view returns (Auction memory) {
        return auctions[tokenId];
    }

    /**
     * @notice Get offer details
     * @param tokenId The token ID
     * @param offerId The offer ID
     */
    function getOffer(uint256 tokenId, uint256 offerId) external view returns (Offer memory) {
        return offers[tokenId][offerId];
    }

    /**
     * @notice Check if an offer is valid (not expired, not accepted, not cancelled)
     * @param tokenId The token ID
     * @param offerId The offer ID
     */
    function isOfferValid(uint256 tokenId, uint256 offerId) external view returns (bool) {
        Offer storage offer = offers[tokenId][offerId];
        return offer.buyer != address(0) &&
               !offer.accepted &&
               !offer.cancelled &&
               block.timestamp < offer.expiresAt;
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Toggle marketplace enabled/disabled
     */
    function toggleMarketplace() external onlyAdmin {
        marketplaceEnabled = !marketplaceEnabled;
        emit MarketplaceToggled(marketplaceEnabled);
    }

    /**
     * @notice Update treasury address
     * @param _treasury New treasury address
     */
    function updateTreasury(address _treasury) external onlyAdmin {
        if (_treasury == address(0)) revert InvalidAddress();
        address oldTreasury = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(oldTreasury, _treasury);
    }

    /**
     * @notice Update payment token addresses
     * @param _dreams DREAMS token address
     * @param _juicy JUICY token address
     */
    function updatePaymentTokens(address _dreams, address _juicy) external onlyAdmin {
        dreamsToken = IERC20(_dreams);
        juicyToken = IERC20(_juicy);
        emit PaymentTokensUpdated(_dreams, _juicy);
    }

    /**
     * @notice Initiate admin transfer
     * @param _newAdmin New admin address
     */
    function transferAdmin(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert InvalidAddress();
        pendingAdmin = _newAdmin;
        emit AdminTransferInitiated(admin, _newAdmin);
    }

    /**
     * @notice Accept admin transfer
     */
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin();
        address oldAdmin = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferCompleted(oldAdmin, admin);
    }

    /**
     * @notice Emergency rescue stuck tokens
     * @param token Token address (address(0) for native)
     * @param amount Amount to rescue
     */
    function rescueTokens(address token, uint256 amount) external onlyAdmin {
        if (token == address(0)) {
            (bool sent, ) = admin.call{value: amount}("");
            if (!sent) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(admin, amount);
        }
    }

    /**
     * @notice Emergency rescue stuck NFT
     * @param tokenId The token ID to rescue
     */
    function rescueNFT(uint256 tokenId) external onlyAdmin {
        // Only if not actively listed/auctioned
        if (listings[tokenId].listingType != ListingType.NONE) revert TokenAlreadyListed();
        if (auctions[tokenId].endTime > block.timestamp && !auctions[tokenId].settled) revert AuctionActive();

        dreamNFT.transferFrom(address(this), admin, tokenId);
    }

    // ============ RECEIVE ============

    receive() external payable {}
}
