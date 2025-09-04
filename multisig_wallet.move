module multiture::multisig {
    use supra_framework::signer;
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::primary_fungible_store;
    use supra_framework::type_info;
    use supra_framework::fungible_asset;
    use supra_framework::coin::{Self};
    use supra_framework::event;
    use supra_framework::account::{Self, SignerCapability};
    use supra_framework::supra_account;
    use supra_framework::object::{Self};
    use aptos_token_objects::token as token_objects;
    use aptos_token::token::{Self, TokenId, initialize_token_store, opt_in_direct_transfer};
    use std::string::{Self, String};
    use std::vector;
    use aptos_std::error;
    use aptos_std::bcs;
    use aptos_std::table::{Self, Table};

    // Initialization errors (0-9)
    const INVALID_SIGNER: u64 = 0;
    const ALREADY_INITIALIZED: u64 = 1;
    const NOT_INITIALIZED: u64 = 2;

    // Multisig errors (10-19)
    const MULTISIG_BANK_DOES_NOT_EXIST: u64 = 10;
    const MULTISIG_DOES_NOT_EXIST: u64 = 11;
    const DUPLICATE_PARTICIPANTS: u64 = 12;
    const INVALID_INPUT_LENGTH: u64 = 13;
    const NAME_TOO_LONG: u64 = 14;

    // Proposal errors (20-29)
    const PROPOSAL_DOES_NOT_EXIST: u64 = 20;
    const PROPOSAL_ALREADY_POSTED: u64 = 21;
    const PROPOSAL_NOT_POSTED: u64 = 22;
    const PROPOSAL_ALREADY_CANCELED: u64 = 23;
    const NOT_ENOUGH_APPROVALS: u64 = 24;
    const NO_PENDING_PARTICIPANT_CHANGES: u64 = 25;
    const ONE_ACTION_PER_PROPOSAL: u64 = 26;
    const PROPOSAL_ALREADY_EXECUTED: u64 = 27;

    // Authorization errors (30-39)
    const UNAUTHORIZED: u64 = 30;
    const SENDER_NOT_AUTHORIZED: u64 = 31;
    const SIGNER_NOT_PROPOSAL_CREATOR: u64 = 32;
    const UNAUTHORIZED_PARTICIPANT: u64 = 33;
    const PARTICIPANTS_EMPTY: u64 = 34;
    const INVALID_APPROVAL_THRESHOLD: u64 = 35;
    const INVALID_CANCELLATION_THRESHOLD: u64 = 36;
    const PARTICIPANTS_BELOW_THRESHOLD: u64 = 37;

    // Asset errors (40-49)
    const ASSET_NOT_SUPPORTED: u64 = 40;
    const INSUFFICIENT_TOKENS: u64 = 41;
    const INSUFFICIENT_FUNDS: u64 = 42;
    const ASSET_NOT_IN_PROPOSAL: u64 = 43;
    const OBJECT_TYPE_NOT_SUPPORTED: u64 = 44;
    const OBJECT_TYPE_NOT_IN_PROPOSAL: u64 = 45;
    const RECORD_NOT_FOUND: u64 = 46;
    const E_SENDER_NOT_OWNER_OF_DA: u64 = 47;

    // Voting errors (50-59)
    const VOTE_NOT_CHANGED: u64 = 50;

    struct MultisigBank has key {
        multisigs: vector<Multisig>,
        resource_accounts: Table<u64, address>,
        resource_signer_caps: Table<u64, SignerCapability>
    }

    struct Multisig has store {
        name: String,
        participants: Table<address, bool>,
        participant_list: vector<address>,
        approval_threshold: u64,
        cancellation_threshold: u64,
        proposals: vector<Proposal>,
    }

    struct PendingTokenWithdrawal has store, drop {
        tokenId: TokenId,
        value: u64,
        recipient: address
    }

    struct PendingFAWithdrawal has copy, store, drop {
        fa_address: address,
        amount: u64,
        recipient: address
    }

    struct PendingCoinWithdrawal has copy, drop, store {
        asset_type: vector<u8>,
        amount: u64,
        recipient: address,
    }

    struct PendingDigitalAssetWithdrawal has copy, store, drop {
        object_address: address,
        recipient: address,
    }

    struct Proposal has store {
        creator: address,
        posted: bool,
        executed: bool,
        votes: Table<address, bool>,
        approval_votes: u64,
        cancellation_votes: u64,
        add_participants: vector<address>,
        remove_participants: vector<address>,
        withdraw_tokens: vector<PendingTokenWithdrawal>,
        withdraw_fa: vector<PendingFAWithdrawal>,
        withdraw_coins: vector<PendingCoinWithdrawal>,
        withdraw_digital_assets: vector<PendingDigitalAssetWithdrawal>,
    }

    struct ProposalDetails has drop {
        proposal_id: u64,
        creator: address,
        posted: bool,
        approval_votes: u64,
        cancellation_votes: u64,
        add_participants: vector<address>,
        remove_participants: vector<address>,
        withdraw_tokens: vector<TokenWithdrawalDetails>,
        withdraw_fa: vector<PendingFAWithdrawal>,
        withdraw_coins: vector<PendingCoinWithdrawal>,
        withdraw_digital_assets: vector<PendingDigitalAssetWithdrawal>
    }

    struct AuthToken has copy, drop, store {
        multisig_id: u64,
        proposal_id: u64
    }

    struct PendingWithdrawalTransferRecord<phantom AssetType> has key {
        record: Table<ProposalID, PendingWithdrawalTransfer>
    }

    struct ProposalID has copy, drop, store {
        multisig_id: u64,
        proposal_id: u64
    }

    struct Config has key {
        admin: address,
        creation_fee: u64,
    }

    struct PendingWithdrawalTransfer has drop, store {
        recipient: address,
        amount: u64
    }

    struct ExposedTokenIdFields has copy, drop, store {
        creator: address,
        collection: String,
        name: String,
        property_version: u64,
    }

    struct TokenWithdrawalDetails has copy, drop {
        tokenId: ExposedTokenIdFields,
        value: u64,
        recipient: address
    }

    struct MultisigDetails has copy, drop {
        id: u64,
        participants: vector<address>,
        name: String,
        approval_threshold: u64,
        cancellation_threshold: u64,
        address: address
    }

    #[event]
    struct MultisigCreatedEvent has drop, store {
        multisig_id: u64,
        participants: vector<address>,
        approval_threshold: u64,
        cancellation_threshold: u64,
    }

    #[event]
    struct DepositEvent has drop, store {
        multisig_id: u64,
        sender: address,
        amount: u64,
        asset_type: vector<u8>,
    }

    #[event]
    struct WithdrawalEvent has drop, store {
        multisig_id: u64,
        proposal_id: u64,
        recipient: address,
        amount: u64,
        asset_type: vector<u8>,
    }

    #[event]
    struct ProposalPostedEvent has drop, store {
        multisig_id: u64,
        proposal_id: u64,
        creator: address,
    }

    #[event]
    struct ParticipantChangesExecutedEvent has drop, store {
        multisig_id: u64,
        proposal_id: u64,
        added_participants: vector<address>,
        removed_participants: vector<address>,
    }

    #[event]
    struct AdminTransferredEvent has drop, store {
        old_admin: address,
        new_admin: address,
    }

    #[event]
    struct CreationFeeChangedEvent has drop, store {
        old_fee: u64,
        new_fee: u64,
    }

    fun init_module(root: &signer) {
        assert!(signer::address_of(root) == @multiture, error::permission_denied(INVALID_SIGNER)); // INVALID_SIGNER 0
        assert!(!exists<MultisigBank>(@multiture), error::already_exists(ALREADY_INITIALIZED)); // ALREADY_INITIALIZED 1
        move_to(root, MultisigBank {
            multisigs: vector::empty<Multisig>(),
            resource_accounts: table::new(),
            resource_signer_caps: table::new()
        });
        move_to(root, Config {
            admin: @multiture,
            creation_fee: 137000000, // 137 SUPRA
    });
    }

    public entry fun enable_deposits_for_multisig<AssetType>(
        account: &signer, 
        multisig_id: u64
    ) acquires MultisigBank {
        let sender_addr = signer::address_of(account);
        let bank = borrow_global_mut<MultisigBank>(@multiture);
        assert!(multisig_id < vector::length(&bank.multisigs), error::not_found(MULTISIG_DOES_NOT_EXIST));
        let multisig = vector::borrow(&bank.multisigs, multisig_id);
        assert!(table::contains<address, bool>(&multisig.participants, sender_addr), error::permission_denied(UNAUTHORIZED_PARTICIPANT));
        let resource_signer_cap = table::borrow(&bank.resource_signer_caps, multisig_id);
        let resource_signer = account::create_signer_with_capability(resource_signer_cap);
        let resource_addr = signer::address_of(&resource_signer);
        assert!(!exists<PendingWithdrawalTransferRecord<AssetType>>(resource_addr), error::already_exists(ALREADY_INITIALIZED));
        move_to(&resource_signer, PendingWithdrawalTransferRecord<AssetType> { record: table::new() });

        if (!coin::is_account_registered<AssetType>(resource_addr)) {
            coin::register<AssetType>(&resource_signer);
        }
    }

    public entry fun create_multisig_entry(
        sender: &signer,
        name: String,
        participants: vector<address>,
        approval_threshold: u64,
        cancellation_threshold: u64
    ) acquires MultisigBank, Config {
        let config = borrow_global<Config>(@multiture);
        let fee = config.creation_fee;
        assert!(coin::balance<SupraCoin>(signer::address_of(sender)) >= fee, error::invalid_state(INSUFFICIENT_FUNDS)); // INSUFFICIENT_FUNDS 42
        assert!(string::length(&name) <= 137, error::invalid_argument(NAME_TOO_LONG));
        if (fee > 0) {
            let fee_coins = coin::withdraw<SupraCoin>(sender, fee);
            coin::deposit<SupraCoin>(config.admin, fee_coins);
        };
        let sender_addr = signer::address_of(sender);
        vector::push_back(&mut participants, sender_addr);
        let seen = vector::empty<address>();
        let len = vector::length(&participants);
        let i = 0;
        while (i < len) {
            let addr = *vector::borrow(&participants, i);
            let j = 0;
            let is_duplicate = false;
            while (j < vector::length(&seen)) {
                let seen_addr = *vector::borrow(&seen, j);
                if (addr == seen_addr) {
                    is_duplicate = true;
                    break
                };
                j = j + 1;
            };
            assert!(!is_duplicate, error::invalid_argument(DUPLICATE_PARTICIPANTS));
            vector::push_back(&mut seen, addr);
            i = i + 1;
        };
        create_multisig(sender, name, participants, approval_threshold, cancellation_threshold);
    }

    public entry fun deposit_entry<AssetType>(
        sender: &signer,
        multisig_id: u64,
        amount: u64
    ) acquires MultisigBank  {
        let bank = borrow_global<MultisigBank>(@multiture);
        assert!(multisig_id < vector::length(&bank.multisigs), error::not_found(MULTISIG_DOES_NOT_EXIST));
        let multisig = vector::borrow(&bank.multisigs, multisig_id);
        let sender_addr = signer::address_of(sender);
        assert!(table::contains(&multisig.participants, sender_addr), error::permission_denied(UNAUTHORIZED_PARTICIPANT)); // UNAUTHORIZED_PARTICIPANT 33
        let resource_addr = *table::borrow(&bank.resource_accounts, multisig_id);
        supra_account::transfer_coins<AssetType>(sender, resource_addr, amount);
        event::emit(DepositEvent {
            multisig_id,
            sender: signer::address_of(sender),
            amount,
            asset_type: bcs::to_bytes(&type_info::type_of<AssetType>()),
        });
    }

    public entry fun deposit_token(
        sender: &signer,
        multisig_id: u64,
        creator: address,
        collection: String,
        name: String,
        property_version: u64,
        amount: u64
    ) acquires MultisigBank {
        let bank = borrow_global<MultisigBank>(@multiture);
        assert!(multisig_id < vector::length(&bank.multisigs), error::not_found(MULTISIG_DOES_NOT_EXIST));
        let resource_addr = *table::borrow(&bank.resource_accounts, multisig_id);
        let token_id = token::create_token_id_raw(creator, collection, name, property_version);
        token::transfer(sender, token_id, resource_addr, amount);
    }

    public entry fun deposit_token_object(
        sender: &signer,
        multisig_id: u64,
        token_object_address: address
    ) acquires MultisigBank {
        let bank = borrow_global<MultisigBank>(@multiture);
        assert!(multisig_id < vector::length(&bank.multisigs), error::not_found(MULTISIG_DOES_NOT_EXIST)); // MULTISIG_DOES_NOT_EXIST 11
        let multisig = vector::borrow(&bank.multisigs, multisig_id);
        let sender_addr = signer::address_of(sender);
        assert!(table::contains(&multisig.participants, sender_addr), error::permission_denied(UNAUTHORIZED_PARTICIPANT)); // UNAUTHORIZED_PARTICIPANT 33
        let resource_addr = *table::borrow(&bank.resource_accounts, multisig_id);
        let asset_to_deposit = object::address_to_object<token_objects::Token>(token_object_address);
        assert!(object::owner(asset_to_deposit) == sender_addr, error::permission_denied(E_SENDER_NOT_OWNER_OF_DA)); // E_SENDER_NOT_OWNER_OF_DA 47
        object::transfer(sender, asset_to_deposit, resource_addr);
        event::emit(DepositEvent {
            multisig_id,
            sender: signer::address_of(sender),
            amount: 1,
            asset_type: bcs::to_bytes(&token_object_address),
        });
    }

    public entry fun create_and_post_add_participants_proposal(
        account: &signer,
        multisig_id: u64,
        new_participants: vector<address>
    ) acquires MultisigBank {
        create_proposal(
            account,
            multisig_id,
            new_participants,   // add_participants
            vector::empty(),    // remove_participants
            vector::empty(),    // withdraw_tokens
            vector::empty(),    // withdraw fa
            vector::empty(),    // withdraw coins
            vector::empty(),
        );

        let multisigs = &mut borrow_global_mut<MultisigBank>(@multiture).multisigs;
        let multisig = vector::borrow_mut(multisigs, multisig_id);
        let proposal_id = vector::length(&multisig.proposals) - 1;
        post_proposal(account, multisig_id, proposal_id);
    }

    public entry fun create_and_post_fa_withdrawal_proposal(
        account: &signer,
        multisig_id: u64,
        fa_address: address,
        amount: u64,
        recipient: address
    ) acquires MultisigBank {
        create_proposal(
            account,
            multisig_id,
            vector::empty(),
            vector::empty(),  
            vector::empty(),
            vector::singleton(PendingFAWithdrawal { fa_address, amount, recipient }),
            vector::empty(),
            vector::empty()
        );
        let multisigs = &mut borrow_global_mut<MultisigBank>(@multiture).multisigs;
        let multisig = vector::borrow_mut(multisigs, multisig_id);
        let proposal_id = vector::length(&multisig.proposals) - 1;
        post_proposal(account, multisig_id, proposal_id);
    }

    public entry fun deposit_fa_entry(
        sender: &signer,
        multisig_id: u64,
        fa_address: address,
        amount: u64
    ) acquires MultisigBank {
        let bank = borrow_global<MultisigBank>(@multiture);
        assert!(multisig_id < vector::length(&bank.multisigs), MULTISIG_DOES_NOT_EXIST);
        let resource_addr = *table::borrow(&bank.resource_accounts, multisig_id);
        let metadata = object::address_to_object<fungible_asset::Metadata>(fa_address);
        primary_fungible_store::transfer(sender, metadata, resource_addr, amount);
        event::emit(DepositEvent {
            multisig_id,
            sender: signer::address_of(sender),
            amount,
            asset_type: bcs::to_bytes(&fa_address),
        });
    }
    
    public entry fun create_and_post_remove_participants_proposal(
        account: &signer,
        multisig_id: u64,
        participants_to_remove: vector<address>
    ) acquires MultisigBank {
        create_proposal(
            account,
            multisig_id,
            vector::empty(),   // add_participants
            participants_to_remove,  // remove_participants
            vector::empty(),    // withdraw_tokens
            vector::empty(),    // withdraw_fa
            vector::empty(),
            vector::empty()
        );

        let multisigs = &mut borrow_global_mut<MultisigBank>(@multiture).multisigs;
        let multisig = vector::borrow_mut(multisigs, multisig_id);
        let proposal_id = vector::length(&multisig.proposals) - 1;
        post_proposal(account, multisig_id, proposal_id);
    }

    public entry fun create_and_post_withdrawal_proposal<AssetType>(
        account: &signer,
        multisig_id: u64,
        recipient: address,
        amount: u64
    ) acquires MultisigBank, PendingWithdrawalTransferRecord {
        let pending_withdrawal = create_pending_coin_withdrawal<AssetType>(amount, recipient);
        create_proposal(
            account,
            multisig_id,
            vector::empty(),  // No participant added
            vector::empty(),  // No participant removals
            vector::empty(),   // No tokens withdrawals
            vector::empty(),   // No FA withdrawals
            vector::singleton(pending_withdrawal),
            vector::empty()
        );
        let multisigs = &mut borrow_global_mut<MultisigBank>(@multiture).multisigs;
        let multisig = vector::borrow_mut(multisigs, multisig_id);
        let proposal_id = vector::length(&multisig.proposals) - 1;
        let resource_addr = *table::borrow(&borrow_global<MultisigBank>(@multiture).resource_accounts, multisig_id);
        if (!exists<PendingWithdrawalTransferRecord<AssetType>>(resource_addr)) {
            enable_deposits_for_multisig<AssetType>(account, multisig_id);
        };
        request_withdrawal_transfer<AssetType>(
            account,
            multisig_id,
            proposal_id,
            recipient,
            amount
        );
        post_proposal(account, multisig_id, proposal_id);
    }

    public entry fun create_and_post_token_withdrawal_proposal(
        account: &signer,
        multisig_id: u64,
        creators: vector<address>,
        collections: vector<String>,
        names: vector<String>,
        property_versions: vector<u64>,
        values: vector<u64>,
        recipients: vector<address>
    ) acquires MultisigBank {
        assert!(vector::length(&creators) == vector::length(&collections), error::invalid_argument(INVALID_INPUT_LENGTH));
        assert!(vector::length(&collections) == vector::length(&names), error::invalid_argument(INVALID_INPUT_LENGTH));
        assert!(vector::length(&names) == vector::length(&property_versions), error::invalid_argument(INVALID_INPUT_LENGTH));
        assert!(vector::length(&property_versions) == vector::length(&values), error::invalid_argument(INVALID_INPUT_LENGTH));
        assert!(vector::length(&values) == vector::length(&recipients), error::invalid_argument(INVALID_INPUT_LENGTH));
        let withdraw_tokens = vector::empty<PendingTokenWithdrawal>();
        let len = vector::length(&creators);
        let i = 0;
        while (i < len) {
            let creator = *vector::borrow(&creators, i);
            let collection = *vector::borrow(&collections, i);
            let name = *vector::borrow(&names, i);
            let property_version = *vector::borrow(&property_versions, i);
            let value = *vector::borrow(&values, i);
            let recipient = *vector::borrow(&recipients, i);
            let tokenId = token::create_token_id_raw(creator, collection, name, property_version);
            vector::push_back(&mut withdraw_tokens, PendingTokenWithdrawal { tokenId, value, recipient });
            i = i + 1;
        };
        create_proposal(
            account,
            multisig_id,
            vector::empty(),
            vector::empty(),
            withdraw_tokens,
            vector::empty(),
            vector::empty(),
            vector::empty()
        );
        let multisigs = &mut borrow_global_mut<MultisigBank>(@multiture).multisigs;
        let multisig = vector::borrow_mut(multisigs, multisig_id);
        let proposal_id = vector::length(&multisig.proposals) - 1;
        post_proposal(account, multisig_id, proposal_id);
    }

    public entry fun create_and_post_digital_asset_withdrawal_proposal(
        account: &signer,
        multisig_id: u64,
        object_addresses: vector<address>, // Direcciones de los Digital Assets a retirar
        recipients: vector<address>        // Destinatarios correspondientes
    ) acquires MultisigBank {
        assert!(vector::length(&object_addresses) == vector::length(&recipients), error::invalid_argument(INVALID_INPUT_LENGTH));  // INVALID_INPUT_LENGTH 13
        let pending_withdrawals = vector::empty<PendingDigitalAssetWithdrawal>();
        let len = vector::length(&object_addresses);
        let i = 0;
        while (i < len) {
            let object_address = *vector::borrow(&object_addresses, i);
            let recipient = *vector::borrow(&recipients, i);
            vector::push_back(&mut pending_withdrawals, PendingDigitalAssetWithdrawal {
                object_address,
                recipient
            });
            i = i + 1;
        };
        create_proposal(
            account,
            multisig_id,
            vector::empty(), // add_participants
            vector::empty(), // remove_participants
            vector::empty(), // withdraw_tokens (0x3)
            vector::empty(), // withdraw_fa (0x1::fungible_asset)
            vector::empty(), // withdraw_coins (0x1::coin)
            pending_withdrawals
        );
        let multisigs = &mut borrow_global_mut<MultisigBank>(@multiture).multisigs;
        let multisig = vector::borrow_mut(multisigs, multisig_id);
        let proposal_id = vector::length(&multisig.proposals) - 1;
        post_proposal(account, multisig_id, proposal_id);
    }

    public entry fun cast_vote(
        account: &signer, 
        multisig_id: u64, 
        proposal_id: u64, 
        vote: bool
    ) acquires MultisigBank {
        assert!(exists<MultisigBank>(@multiture), error::not_found(MULTISIG_BANK_DOES_NOT_EXIST)); // MULTISIG_BANK_DOES_NOT_EXIST 10
        let multisigs = &mut borrow_global_mut<MultisigBank>(@multiture).multisigs;
        assert!(multisig_id < vector::length(multisigs), error::not_found(MULTISIG_DOES_NOT_EXIST)); // MULTISIG_DOES_NOT_EXIST 11
        let multisig = vector::borrow_mut(multisigs, multisig_id);
        assert!(proposal_id < vector::length(&multisig.proposals), error::not_found(PROPOSAL_DOES_NOT_EXIST)); // MULTISIG_DOES_NOT_EXIST 20
        let proposal: &mut Proposal = vector::borrow_mut(&mut multisig.proposals, proposal_id);
        assert!(*&proposal.posted, error::not_found(PROPOSAL_NOT_POSTED)); // PROPOSAL_NOT_POSTED 22
        assert!(*&proposal.cancellation_votes < *&multisig.cancellation_threshold, error::invalid_state(PROPOSAL_ALREADY_CANCELED)); // PROPOSAL_ALREADY_CANCELED 23
        let sender = signer::address_of(account);
        assert!(table::contains(&multisig.participants, sender) && *table::borrow(&multisig.participants, sender), error::permission_denied(UNAUTHORIZED_PARTICIPANT)); // UNAUTHORIZED_PARTICIPANT 33
        if (table::contains(&proposal.votes, sender)) {
            let old_vote = table::remove(&mut proposal.votes, sender);
            assert!(vote != old_vote, VOTE_NOT_CHANGED); // VOTE_NOT_CHANGED 50
            if (old_vote) *&mut proposal.approval_votes = *&proposal.approval_votes - 1
            else *&mut proposal.cancellation_votes = *&proposal.cancellation_votes - 1;
        };
        table::add(&mut proposal.votes, sender, vote);
        if (vote) *&mut proposal.approval_votes = *&proposal.approval_votes + 1
        else *&mut proposal.cancellation_votes = *&proposal.cancellation_votes + 1;
    }

    public entry fun execute_participant_changes(
        executor: &signer,
        multisig_id: u64,
        proposal_id: u64
    ) acquires MultisigBank {
        assert!(exists<MultisigBank>(@multiture), error::not_found(MULTISIG_BANK_DOES_NOT_EXIST)); // MULTISIG_BANK_DOES_NOT_EXIST 10
        let multisigs = &mut borrow_global_mut<MultisigBank>(@multiture).multisigs;
        assert!(multisig_id < vector::length(multisigs), error::not_found(MULTISIG_DOES_NOT_EXIST)); // MULTISIG_DOES_NOT_EXIST 11
        let multisig = vector::borrow_mut(multisigs, multisig_id);
        assert_is_participant(multisig, executor);
        assert!(proposal_id < vector::length(&multisig.proposals), error::not_found(PROPOSAL_DOES_NOT_EXIST)); // MULTISIG_DOES_NOT_EXIST 20
        let proposal: &mut Proposal = vector::borrow_mut(&mut multisig.proposals, proposal_id);
        assert!(!proposal.executed, error::invalid_state(PROPOSAL_ALREADY_EXECUTED));
        assert!(proposal.approval_votes >= multisig.approval_threshold, error::invalid_state(NOT_ENOUGH_APPROVALS)); // NOT_ENOUGH_APPROVALS 24
        assert!(proposal.cancellation_votes < multisig.cancellation_threshold, error::invalid_state(PROPOSAL_ALREADY_CANCELED)); // PROPOSAL_ALREADY_CANCELED 23
        let new_participant_count = vector::length(&multisig.participant_list) 
        + vector::length(&proposal.add_participants) 
        - vector::length(&proposal.remove_participants);
        assert!(new_participant_count >= multisig.approval_threshold, PARTICIPANTS_BELOW_THRESHOLD); 
        assert!(!vector::is_empty(&proposal.remove_participants) || !vector::is_empty(&proposal.add_participants), error::invalid_argument(NO_PENDING_PARTICIPANT_CHANGES)); // NO_PENDING_PARTICIPANT_CHANGES 25
        let added_participants = vector::empty<address>();
        let removed_participants = vector::empty<address>();
        while (!vector::is_empty(&proposal.remove_participants)) {
            let participant = vector::pop_back(&mut proposal.remove_participants);
            if (table::contains(&multisig.participants, participant)) {
                table::remove(&mut multisig.participants, participant);
                let (found, index) = vector::index_of(&multisig.participant_list, &participant);
                if (found) {
                    vector::remove(&mut multisig.participant_list, index);
                };
                vector::push_back(&mut removed_participants, participant); // Record successful removal
            }
        };

        while (!vector::is_empty(&proposal.add_participants)) {
            let participant = vector::pop_back(&mut proposal.add_participants);
            if (!table::contains(&multisig.participants, participant)) {
                table::add(&mut multisig.participants, participant, true);
                vector::push_back(&mut multisig.participant_list, participant);
                vector::push_back(&mut added_participants, participant); // Record successful addition
            } else if (!*table::borrow(&multisig.participants, participant)) {
                *table::borrow_mut(&mut multisig.participants, participant) = true;
                vector::push_back(&mut added_participants, participant); // Record successful reactivation
            }
        };
        
        proposal.executed = true;
    
        event::emit(ParticipantChangesExecutedEvent {
            multisig_id,
            proposal_id,
            added_participants,
            removed_participants,
        });
    }

    public entry fun execute_token_withdrawals(
        executor: &signer,
        multisig_id: u64,
        proposal_id: u64
    ) acquires MultisigBank {
        let bank = borrow_global_mut<MultisigBank>(@multiture);
        let multisigs = &mut bank.multisigs;
        assert!(multisig_id < vector::length(multisigs), error::not_found(MULTISIG_DOES_NOT_EXIST));
        let multisig = vector::borrow_mut(multisigs, multisig_id);
        assert_is_participant(multisig, executor);
        assert!(proposal_id < vector::length(&multisig.proposals), error::not_found(PROPOSAL_DOES_NOT_EXIST));
        let proposal_ref = vector::borrow(&multisig.proposals, proposal_id); // Primero un borrow inmutable
        assert!(!vector::is_empty(&proposal_ref.withdraw_tokens), error::invalid_argument(ASSET_NOT_IN_PROPOSAL));
        let proposal = vector::borrow_mut(&mut multisig.proposals, proposal_id);
        assert!(!proposal.executed, error::invalid_state(PROPOSAL_ALREADY_EXECUTED));
        assert!(proposal.approval_votes >= multisig.approval_threshold, error::invalid_state(NOT_ENOUGH_APPROVALS));
        assert!(proposal.cancellation_votes < multisig.cancellation_threshold, error::invalid_state(PROPOSAL_ALREADY_CANCELED));
        let resource_signer_cap = table::borrow(&bank.resource_signer_caps, multisig_id);
        let resource_signer = account::create_signer_with_capability(resource_signer_cap );
        while (!vector::is_empty(&proposal.withdraw_tokens)) {
            let pending_token_withdrawal = vector::pop_back(&mut proposal.withdraw_tokens);
            let original_token_id = pending_token_withdrawal.tokenId;
            let amount = pending_token_withdrawal.value;
            let recipient_addr = pending_token_withdrawal.recipient;
            let (creator_addr, collection_name_str, token_name_str, property_version_num) = token::get_token_id_fields(&original_token_id);
            token::transfer_with_opt_in(&resource_signer, creator_addr, collection_name_str, token_name_str, property_version_num, recipient_addr, amount);
        };
    
        proposal.executed = true;

    }
    
    public entry fun execute_withdraw_to<AssetType>(
        executor: &signer,
        multisig_id: u64,
        proposal_id: u64
    ) acquires MultisigBank, PendingWithdrawalTransferRecord {
        let bank = borrow_global_mut<MultisigBank>(@multiture);
        let multisigs = &mut bank.multisigs;
        assert!(multisig_id < vector::length(multisigs), error::not_found(MULTISIG_DOES_NOT_EXIST));
        let multisig = vector::borrow_mut(multisigs, multisig_id);
        assert_is_participant(multisig, executor);
        assert!(proposal_id < vector::length(&multisig.proposals), error::not_found(PROPOSAL_DOES_NOT_EXIST));
        let proposal: &mut Proposal = vector::borrow_mut(&mut multisig.proposals, proposal_id);
        assert!(!proposal.executed, error::invalid_state(PROPOSAL_ALREADY_EXECUTED));
        assert!(proposal.approval_votes >= multisig.approval_threshold, error::invalid_state(NOT_ENOUGH_APPROVALS));
        assert!(proposal.cancellation_votes < multisig.cancellation_threshold, error::invalid_state(PROPOSAL_ALREADY_CANCELED));
        let resource_addr = *table::borrow(&bank.resource_accounts, multisig_id);
        assert!(exists<PendingWithdrawalTransferRecord<AssetType>>(resource_addr), error::invalid_argument(ASSET_NOT_SUPPORTED));
        let record = &mut borrow_global_mut<PendingWithdrawalTransferRecord<AssetType>>(resource_addr).record;
        let combined_id = ProposalID { multisig_id, proposal_id };
        assert!(table::contains(record, combined_id), error::not_found(ASSET_NOT_IN_PROPOSAL));
        let transfer_data = table::remove(record, combined_id);
        let resource_signer_cap = table::borrow(&bank.resource_signer_caps, multisig_id);
        let resource_signer = account::create_signer_with_capability(resource_signer_cap);
        let balance = coin::balance<AssetType>(signer::address_of(&resource_signer));
        assert!(balance >= transfer_data.amount, error::invalid_state(INSUFFICIENT_FUNDS));
        supra_account::transfer_coins<AssetType>(&resource_signer, transfer_data.recipient, transfer_data.amount);
        event::emit(WithdrawalEvent {
            multisig_id,
            proposal_id,
            recipient: transfer_data.recipient,
            amount: transfer_data.amount,
            asset_type: bcs::to_bytes(&type_info::type_of<AssetType>()),
        });
        let asset_type_bytes = bcs::to_bytes(&type_info::type_of<AssetType>());
        let len = vector::length(&proposal.withdraw_coins);
        let i = 0;
        while (i < len) {
            let withdrawal = vector::borrow(&proposal.withdraw_coins, i);
            if (withdrawal.asset_type == asset_type_bytes) {
                vector::remove(&mut proposal.withdraw_coins, i);
                break
            };
            i = i + 1;
        };
        if (vector::is_empty(&proposal.withdraw_coins)) {
            proposal.executed = true;
        };
    }

    public entry fun execute_withdraw_fa(
        executor: &signer,
        multisig_id: u64,
        proposal_id: u64
    ) acquires MultisigBank {
        let bank = borrow_global_mut<MultisigBank>(@multiture);
        let multisigs = &mut bank.multisigs;
        assert!(multisig_id < vector::length(multisigs), error::not_found(MULTISIG_DOES_NOT_EXIST));
        let multisig = vector::borrow_mut(multisigs, multisig_id);
        assert_is_participant(multisig, executor);
        assert!(proposal_id < vector::length(&multisig.proposals), error::not_found(PROPOSAL_DOES_NOT_EXIST));
        let proposal: &mut Proposal = vector::borrow_mut(&mut multisig.proposals, proposal_id);
        assert!(proposal.approval_votes >= multisig.approval_threshold, error::invalid_state(NOT_ENOUGH_APPROVALS));
        assert!(proposal.cancellation_votes < multisig.cancellation_threshold, error::invalid_state(PROPOSAL_ALREADY_CANCELED));
        assert!(!proposal.executed, error::invalid_state(PROPOSAL_ALREADY_EXECUTED));
        let resource_signer_cap = table::borrow(&bank.resource_signer_caps, multisig_id);
        let resource_signer = account::create_signer_with_capability(resource_signer_cap);
        while (!vector::is_empty(&proposal.withdraw_fa)) {
            let pending_fa_withdrawal = vector::pop_back(&mut proposal.withdraw_fa);
            let fa_address = pending_fa_withdrawal.fa_address;
            let amount = pending_fa_withdrawal.amount;
            let recipient = pending_fa_withdrawal.recipient;
            let metadata = object::address_to_object<fungible_asset::Metadata>(fa_address);
            primary_fungible_store::transfer(&resource_signer, metadata, recipient, amount);
            event::emit(WithdrawalEvent {
                multisig_id,
                proposal_id,
                recipient,
                amount,
                asset_type: bcs::to_bytes(&fa_address),
            });
        };

        proposal.executed = true;
    }

    public entry fun execute_digital_asset_withdrawals(
        executor: &signer,
        multisig_id: u64,
        proposal_id: u64
    ) acquires MultisigBank {
        assert!(exists<MultisigBank>(@multiture), error::not_found(MULTISIG_BANK_DOES_NOT_EXIST)); // MULTISIG_BANK_DOES_NOT_EXIST 10
        let bank_ref = borrow_global<MultisigBank>(@multiture);
        assert!(multisig_id < vector::length(&bank_ref.multisigs), error::not_found(MULTISIG_DOES_NOT_EXIST)); // MULTISIG_DOES_NOT_EXIST 11
        let multisig_ref = vector::borrow(&bank_ref.multisigs, multisig_id);
        assert!(proposal_id < vector::length(&multisig_ref.proposals), error::not_found(PROPOSAL_DOES_NOT_EXIST)); // PROPOSAL_DOES_NOT_EXIST 20
        let proposal_ref_immutable = vector::borrow(&multisig_ref.proposals, proposal_id);
        assert!(!vector::is_empty(&proposal_ref_immutable.withdraw_digital_assets), error::invalid_argument(ASSET_NOT_IN_PROPOSAL));
        let bank = borrow_global_mut<MultisigBank>(@multiture);
        let multisigs = &mut bank.multisigs;
        assert!(multisig_id < vector::length(multisigs), error::not_found(MULTISIG_DOES_NOT_EXIST)); // MULTISIG_DOES_NOT_EXIST 11
        let multisig = vector::borrow_mut(multisigs, multisig_id);
        assert_is_participant(multisig, executor);
        assert!(proposal_id < vector::length(&multisig.proposals), error::not_found(PROPOSAL_DOES_NOT_EXIST)); // PROPOSAL_DOES_NOT_EXIST 20
        let proposal = vector::borrow_mut(&mut multisig.proposals, proposal_id);
        assert!(!proposal.executed, error::invalid_state(PROPOSAL_ALREADY_EXECUTED)); // PROPOSAL_ALREADY_EXECUTED 27
        assert!(proposal.approval_votes >= multisig.approval_threshold, error::invalid_state(NOT_ENOUGH_APPROVALS)); // NOT_ENOUGH_APPROVALS 24
        assert!(proposal.cancellation_votes < multisig.cancellation_threshold, error::invalid_state(PROPOSAL_ALREADY_CANCELED)); // PROPOSAL_ALREADY_CANCELED 23
        let resource_signer_cap = table::borrow(&bank.resource_signer_caps, multisig_id);
        let resource_signer = account::create_signer_with_capability(resource_signer_cap);
        let resource_addr = signer::address_of(&resource_signer);
        while (!vector::is_empty(&proposal.withdraw_digital_assets)) {
            let pending_da_withdrawal = vector::pop_back(&mut proposal.withdraw_digital_assets);
            let object_address = pending_da_withdrawal.object_address;
            let recipient = pending_da_withdrawal.recipient;
            let asset_to_transfer = object::address_to_object<token_objects::Token>(object_address);
            assert!(object::owner(asset_to_transfer) == resource_addr, error::permission_denied(UNAUTHORIZED));
            object::transfer(&resource_signer, asset_to_transfer, recipient);
            event::emit(WithdrawalEvent {
                multisig_id,
                proposal_id,
                recipient,
                amount: 1,
                asset_type: bcs::to_bytes(&object_address),
            });
        };

        proposal.executed = true;
        
    }

    public entry fun set_creation_fee(
        admin: &signer, 
        new_fee: u64
    ) acquires Config {
        let config = borrow_global_mut<Config>(@multiture);
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == config.admin, error::permission_denied(UNAUTHORIZED));
        let old_fee = config.creation_fee;
        config.creation_fee = new_fee;
        event::emit(CreationFeeChangedEvent { old_fee, new_fee });
    }

    public entry fun transfer_admin(
        current_admin: &signer, 
        new_admin: address
    ) acquires Config {
        let config = borrow_global_mut<Config>(@multiture);
        let current_admin_addr = signer::address_of(current_admin);
        assert!(current_admin_addr == config.admin, error::permission_denied(UNAUTHORIZED)); // UNAUTHORIZED 30
        let old_admin = config.admin;
        config.admin = new_admin;
        event::emit(AdminTransferredEvent {
            old_admin,
            new_admin,
        });
    }

    fun create_multisig(
        root: &signer, 
        name: String, 
        participants: vector<address>, 
        approval_threshold: u64, 
        cancellation_threshold: u64
    ): u64 acquires MultisigBank {
        let participants_copy = copy participants;
        assert!(!vector::is_empty(&participants), error::invalid_argument(PARTICIPANTS_EMPTY)); // PARTICIPANTS_EMPTY 34
        assert!(vector::length(&participants) >= approval_threshold, error::invalid_argument(INVALID_APPROVAL_THRESHOLD));
        assert!(vector::length(&participants) >= cancellation_threshold, error::invalid_argument(INVALID_CANCELLATION_THRESHOLD));

        let multisig = Multisig { 
            name,
            participants: table::new(),
            participant_list: copy participants_copy,
            approval_threshold, 
            cancellation_threshold, 
            proposals: vector::empty(), 
        };
        while (!vector::is_empty(&participants)) {
            let participant = vector::pop_back(&mut participants);
            table::add(&mut multisig.participants, participant, true);
        };

        let bank = borrow_global_mut<MultisigBank>(@multiture);
        let multisig_id = vector::length(&bank.multisigs);
        let seed = vector::empty<u8>();
        vector::append(&mut seed, *string::bytes(&name));
        vector::append(&mut seed, bcs::to_bytes(&multisig_id));
        let (resource_signer, resource_cap) = account::create_resource_account(root, seed);
        let resource_account_addr = signer::address_of(&resource_signer);
        initialize_token_store(&resource_signer);
        opt_in_direct_transfer(&resource_signer, true); 
        table::add(&mut bank.resource_accounts, multisig_id, resource_account_addr);
        table::add(&mut bank.resource_signer_caps, multisig_id, resource_cap);
        vector::push_back(&mut bank.multisigs, multisig);
        event::emit(MultisigCreatedEvent {
            multisig_id,
            participants: copy participants_copy,
            approval_threshold,
            cancellation_threshold,
        });
        multisig_id
    }

    fun create_pending_coin_withdrawal<AssetType>(
        amount: u64, 
        recipient: address
        ): PendingCoinWithdrawal {
        PendingCoinWithdrawal {
            asset_type: bcs::to_bytes(&type_info::type_of<AssetType>()), // Serializa el tipo de moneda
            amount,
            recipient,
        }
    }

    fun assert_is_participant(
        multisig: &Multisig, 
        executor: &signer
    ) {
        let executor_addr = signer::address_of(executor);
        assert!(
            table::contains(&multisig.participants, executor_addr) && 
            *table::borrow(&multisig.participants, executor_addr), 
            error::permission_denied(UNAUTHORIZED_PARTICIPANT)
        );
    }

    public fun request_withdrawal_transfer<AssetType>(
        account: &signer, 
        multisig_id: u64, 
        proposal_id: u64, 
        recipient: address, 
        amount: u64
    ) acquires MultisigBank, PendingWithdrawalTransferRecord {
        assert!(exists<MultisigBank>(@multiture), error::not_found(MULTISIG_BANK_DOES_NOT_EXIST)); // MULTISIG_BANK_DOES_NOT_EXIST 10
        let bank = borrow_global<MultisigBank>(@multiture);
        let multisigs = &bank.multisigs;
        assert!(multisig_id < vector::length(multisigs), error::not_found(MULTISIG_DOES_NOT_EXIST)); // MULTISIG_DOES_NOT_EXIST 11
        let proposals = &vector::borrow(multisigs, multisig_id).proposals;
        assert!(proposal_id < vector::length(proposals), error::not_found(PROPOSAL_DOES_NOT_EXIST)); // PROPOSAL_DOES_NOT_EXIST 20
        let proposal = vector::borrow(proposals, proposal_id);
        assert!(!proposal.posted, error::invalid_state(PROPOSAL_ALREADY_POSTED)); // PROPOSAL_ALREADY_POSTED 21
        let sender = signer::address_of(account);
        assert!(sender == proposal.creator, error::permission_denied(SIGNER_NOT_PROPOSAL_CREATOR)); // SIGNER_NOT_PROPOSAL_CREATOR 32
        let resource_addr = *table::borrow(&bank.resource_accounts, multisig_id);
        assert!(exists<PendingWithdrawalTransferRecord<AssetType>>(resource_addr), error::invalid_argument(ASSET_NOT_SUPPORTED)); // ASSET_NOT_SUPPORTED 40
        let record = &mut borrow_global_mut<PendingWithdrawalTransferRecord<AssetType>>(resource_addr).record;
        let combined_id = ProposalID { multisig_id, proposal_id };
        if (table::contains(record, combined_id)) {
            table::remove(record, combined_id);
        };
        let transfer_data = PendingWithdrawalTransfer { recipient, amount };
        table::add(record, combined_id, transfer_data)
    }

    public fun create_pending_token_withdrawal(
        tokenId: TokenId, 
        value: u64, 
        recipient: address
    ): PendingTokenWithdrawal {
        PendingTokenWithdrawal {
            tokenId,
            value,
            recipient
        }
    }

    public fun create_proposal(
        account: &signer,
        multisig_id: u64,
        add_participants: vector<address>,
        remove_participants: vector<address>,
        withdraw_tokens: vector<PendingTokenWithdrawal>, //Fungible Assets only or NFTs
        withdraw_fa: vector<PendingFAWithdrawal>,
        withdraw_coins: vector<PendingCoinWithdrawal>,
        withdraw_digital_assets: vector<PendingDigitalAssetWithdrawal>
    ) acquires MultisigBank {
        let actions_count = 0;
        if (!vector::is_empty(&add_participants) || !vector::is_empty(&remove_participants)) {
            actions_count = actions_count + 1;
        };
        if (!vector::is_empty(&withdraw_tokens)) {
            actions_count = actions_count + 1;
        };
        if (!vector::is_empty(&withdraw_fa)) {
            actions_count = actions_count + 1;
        };
        if (!vector::is_empty(&withdraw_coins)) {
            actions_count = actions_count + 1;
        };
        if (!vector::is_empty(&withdraw_digital_assets)) {
            actions_count = actions_count + 1;
        };
        assert!(actions_count == 1, error::invalid_argument(ONE_ACTION_PER_PROPOSAL));
        assert!(exists<MultisigBank>(@multiture), error::not_found(MULTISIG_BANK_DOES_NOT_EXIST)); // MULTISIG_BANK_DOES_NOT_EXIST 10
        let multisigs = &mut borrow_global_mut<MultisigBank>(@multiture).multisigs;
        assert!(multisig_id < vector::length(multisigs), error::not_found(MULTISIG_DOES_NOT_EXIST)); // MULTISIG_DOES_NOT_EXIST 11
        let multisig = vector::borrow_mut(multisigs, multisig_id);
        let sender = signer::address_of(account);
        assert!(table::contains(&multisig.participants, sender), error::permission_denied(SENDER_NOT_AUTHORIZED)); // SENDER_NOT_AUTHORIZED 31
        vector::push_back(&mut multisig.proposals, Proposal {
            creator: sender,
            posted: false,
            executed: false,
            votes: table::new(),
            approval_votes: 0,
            cancellation_votes: 0,
            add_participants,
            remove_participants,
            withdraw_tokens,
            withdraw_fa,
            withdraw_coins,
            withdraw_digital_assets
        });
    }

    // TL;DR: Marks a multisig proposal as "posted" and returns an AuthToken proving it.
    // Only the creator of the proposal can do this.
    public fun post_proposal(
        account: &signer, 
        multisig_id: u64, 
        proposal_id: u64
    ): AuthToken acquires MultisigBank {
        assert!(exists<MultisigBank>(@multiture), error::not_found(MULTISIG_BANK_DOES_NOT_EXIST)); // MULTISIG_BANK_DOES_NOT_EXIST 10
        let multisigs = &mut borrow_global_mut<MultisigBank>(@multiture).multisigs;
        assert!(multisig_id < vector::length(multisigs), error::not_found(MULTISIG_DOES_NOT_EXIST)); // MULTISIG_DOES_NOT_EXIST 11
        let proposals = &mut vector::borrow_mut(multisigs, multisig_id).proposals;
        assert!(proposal_id < vector::length(proposals), error::not_found(PROPOSAL_DOES_NOT_EXIST)); // MULTISIG_DOES_NOT_EXIST 20
        let proposal = vector::borrow_mut(proposals, proposal_id);
        assert!(!*&proposal.posted, error::invalid_state(PROPOSAL_ALREADY_POSTED)); // PROPOSAL_ALREADY_POSTED 21
        let sender = signer::address_of(account);
        assert!(sender == *&proposal.creator, error::permission_denied(SIGNER_NOT_PROPOSAL_CREATOR)); // SIGNER_NOT_PROPOSAL_CREATOR 32
        *&mut proposal.posted = true;
        event::emit(ProposalPostedEvent {
            multisig_id,
            proposal_id,
            creator: sender,
        });

        AuthToken { multisig_id, proposal_id }
    }

    #[view]
    public fun get_multisig_ids_for_address(addr: address): vector<u64> acquires MultisigBank {
        let bank = borrow_global<MultisigBank>(@multiture);
        let ids = vector::empty<u64>();
        let len = vector::length(&bank.multisigs);
        let i = 0;
        while (i < len) {
            let multisig = vector::borrow(&bank.multisigs, i);
            if (table::contains(&multisig.participants, addr)) {
                vector::push_back(&mut ids, i);
            };
            i = i + 1;
        };
        ids
    }

    #[view]
    public fun get_multisig_details(multisig_id: u64): (vector<address>, String, u64, u64, address) acquires MultisigBank {
        let bank = borrow_global<MultisigBank>(@multiture);
        assert!(multisig_id < vector::length(&bank.multisigs), error::not_found(MULTISIG_DOES_NOT_EXIST));
        let multisig = vector::borrow(&bank.multisigs, multisig_id);
        let resource_addr = *table::borrow(&bank.resource_accounts, multisig_id);
        (
            multisig.participant_list,
            multisig.name,
            multisig.approval_threshold,
            multisig.cancellation_threshold,
            resource_addr 
        )
    }

    #[view]
    public fun get_multisig_details_for_address(addr: address): vector<MultisigDetails> acquires MultisigBank {
        let ids = get_multisig_ids_for_address(addr); // Still unbound, addressed next
        let details = vector::empty<MultisigDetails>(); // Use the new struct
        let len = vector::length(&ids);
        let i = 0;
        while (i < len) {
            let id = *vector::borrow(&ids, i);
            let (participants, name, approval, cancellation, resource_addr) = get_multisig_details(id); // Still unbound, addressed next
            vector::push_back(&mut details, MultisigDetails {
                id,
                participants,
                name,
                approval_threshold: approval,
                cancellation_threshold: cancellation,
                address: resource_addr,
            });
            i = i + 1;
        };
        details
    }

    #[view]
    public fun get_pending_proposals_details(multisig_id: u64): vector<ProposalDetails> acquires MultisigBank {
        let bank = borrow_global<MultisigBank>(@multiture);
        assert!(multisig_id < vector::length(&bank.multisigs), error::not_found(MULTISIG_DOES_NOT_EXIST));
        let multisig = vector::borrow(&bank.multisigs, multisig_id);
        let pending_proposals = vector::empty<ProposalDetails>();
        let len = vector::length(&multisig.proposals);
        let i = 0;
        while (i < len) {
            let proposal = vector::borrow(&multisig.proposals, i);
            if (proposal.posted && 
                proposal.approval_votes < multisig.approval_threshold && 
                proposal.cancellation_votes < multisig.cancellation_threshold) {
                let token_withdrawals = vector::empty<TokenWithdrawalDetails>();
                let j = 0;
                while (j < vector::length(&proposal.withdraw_tokens)) {
                    let token_withdrawal = vector::borrow(&proposal.withdraw_tokens, j);
                    let original_token_id = token_withdrawal.tokenId;
                    let (creator, collection, name, property_version) = token::get_token_id_fields(&original_token_id );
                    let exposed_token_id = ExposedTokenIdFields {
                        creator,
                        collection,
                        name,
                        property_version
                    };
                    vector::push_back(&mut token_withdrawals, TokenWithdrawalDetails {
                        tokenId: exposed_token_id,
                        value: token_withdrawal.value,
                        recipient: token_withdrawal.recipient
                    });
                    j = j + 1;
                };

                vector::push_back(&mut pending_proposals, ProposalDetails {
                    proposal_id: i,
                    creator: proposal.creator,
                    posted: proposal.posted,
                    approval_votes: proposal.approval_votes,
                    cancellation_votes: proposal.cancellation_votes,
                    add_participants: proposal.add_participants,
                    remove_participants: proposal.remove_participants,
                    withdraw_tokens: token_withdrawals,
                    withdraw_fa: proposal.withdraw_fa,
                    withdraw_coins: proposal.withdraw_coins,
                    withdraw_digital_assets: proposal.withdraw_digital_assets,
                });
            };
            i = i + 1;
        };
        pending_proposals
    }

    #[view]
    public fun get_approved_proposals_details(multisig_id: u64): vector<ProposalDetails> acquires MultisigBank {
        let bank = borrow_global<MultisigBank>(@multiture);
        assert!(multisig_id < vector::length(&bank.multisigs), error::not_found(MULTISIG_DOES_NOT_EXIST));
        let multisig = vector::borrow(&bank.multisigs, multisig_id);
        let approved_proposals = vector::empty<ProposalDetails>();
        let len = vector::length(&multisig.proposals);
        let i = 0;
        while (i < len) {
            let proposal = vector::borrow(&multisig.proposals, i);
            if (proposal.posted &&
                !proposal.executed &&
                proposal.approval_votes >= multisig.approval_threshold && 
                proposal.cancellation_votes < multisig.cancellation_threshold) {
                let token_withdrawals = vector::empty<TokenWithdrawalDetails>();
                let j = 0;
                while (j < vector::length(&proposal.withdraw_tokens)) {
                    let token_withdrawal = vector::borrow(&proposal.withdraw_tokens, j);
                    let original_token_id = token_withdrawal.tokenId;
                    let (creator, collection, name, property_version) = token::get_token_id_fields(&original_token_id);
                    let exposed_token_id = ExposedTokenIdFields {
                        creator,
                        collection,
                        name,
                        property_version
                    };
                    vector::push_back(&mut token_withdrawals, TokenWithdrawalDetails {
                        tokenId: exposed_token_id,
                        value: token_withdrawal.value,
                        recipient: token_withdrawal.recipient
                    });
                    j = j + 1;
                };
                vector::push_back(&mut approved_proposals, ProposalDetails {
                    proposal_id: i,
                    creator: proposal.creator,
                    posted: proposal.posted,
                    approval_votes: proposal.approval_votes,
                    cancellation_votes: proposal.cancellation_votes,
                    add_participants: proposal.add_participants,
                    remove_participants: proposal.remove_participants,
                    withdraw_tokens: token_withdrawals,
                    withdraw_fa: proposal.withdraw_fa,
                    withdraw_coins: proposal.withdraw_coins,
                    withdraw_digital_assets: proposal.withdraw_digital_assets,
                });
            };
            i = i + 1;
        };
        approved_proposals
    }
}
