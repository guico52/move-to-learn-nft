// Certificate issuance module
module dev::certificate {

    use std::option;
    use std::option::Option;
    use std::signer;
    use std::string::{utf8, String};
    use std::vector;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_framework::coin;
    use aptos_framework::event;
    use aptos_framework::object;
    use aptos_framework::object::Object;
    use aptos_token_objects::token::Token;
    use aptos_token_objects::collection::Collection;
    use aptos_token_objects::royalty;
    use aptos_token_objects::token;
    use aptos_token_objects::collection;

    // Error codes
    const E_NOT_ADMIN: u64 = 1;
    // Caller is not admin
    const E_ALREADY_CLAIMED: u64 = 2;
    // Course already claimed
    const E_INSUFFICIENT_BALANCE: u64 = 3;
    // Insufficient balance
    const E_COURSE_NOT_EXISTS: u64 = 4;
    // Course does not exist
    const E_ALREADY_HAVE_CERTIFICATE: u64 = 5;
    // Already have certificate
    const E_COURSE_ALREADY_EXISTS: u64 = 6;
    // Course already exists
    const E_COURSE_NOT_FOUND: u64 = 7; 
    // Course not found

    const ADMIN_ADDRESS: address = @dev; // Admin address
    const ROYALTY_NUMERATOR: u64 = 100;
    const ROYALTY_DENOMINATOR: u64 = 100;

    // const SELL_BANNED_ROYALTY: Royalty = royalty::create(1, 1, @dev);
    // Type definitions

    // User points system and capabilities
    struct M2LCoin has store {}

    struct MintStore has key { cap: coin::MintCapability<M2LCoin> }

    struct BurnStore has key { cap: coin::BurnCapability<M2LCoin> }

    struct FreezeStore has key { cap: coin::FreezeCapability<M2LCoin> }

    // Course metadata structure
    struct CourseMeta has store, drop, copy {
        points: u64,
        metadata_uri: String,
    }

    // Course registry
    struct CourseRegistry has key {
        courses: SimpleMap<String, CourseMeta>
    }

    // Course certificate collection
    struct CourseCollection has key {
        collection_address: address
    }

    // Course certificate NFT
    struct CourseCertificate has key, store, copy {
        token: Object<token::Token>,
        token_address: address,
        user: address,
        course_id: String
    }

    // User certificate record table
    struct UserCertificatesTable has key {
        certificates: SimpleMap<String, SimpleMap<address, CourseCertificate>> // course_id ->  user_id -> CourseCertificate
    }

    // Mint certificate event
    #[event]
    struct MintCertificateEvent has drop, store {
        course_id: String,
        recipient: address,
        token_id: address,
        timestamp: u64,
        points: u64,
        status: String, // started/completed
    }

    // Course register event
    #[event]
    struct CourseRegisterEvent has drop, store {
        course_id: String,
        points: u64,
        timestamp: u64,
        operation_type: String, // new/update/delete
        metadata_uri: String,
    }

    // Coin mint event
    #[event]
    struct CoinMintEvent has drop, store {
        recipient: address,
        amount: u64,
        timestamp: u64,
    }

    // Certificate transfer event
    #[event]
    struct CertificateTransferEvent has drop, store {
        course_id: String,
        from: address,
        to: address,
        token_id: address,
        timestamp: u64,
    }

    // Error event
    #[event]
    struct ErrorEvent has drop, store {
        error_code: u64,
        error_message: String,
        timestamp: u64,
    }

    // ================= Contract Interaction Part ====================
    // Initialize contract
    public entry fun initialize(admin: &signer) {
        assert!(is_admin(admin), E_NOT_ADMIN);
        move_to(admin, CourseRegistry {
            courses: simple_map::new()
        });
        let coin_name = utf8(b"m2l_coin");
        let coin_symbol = utf8(b"m2l");
        // Register coin
        let (burn, freeze, mint) =
            coin::initialize<M2LCoin>(admin, coin_name, coin_symbol, 8, false);
        // Store coin's mint, burn, freeze capabilities
        move_to(admin, MintStore { cap: mint });
        move_to(admin, BurnStore { cap: burn });
        move_to(admin, FreezeStore { cap: freeze });
    }

    // Register/update course
    public entry fun set_course(
        admin: &signer,
        course_id: String,
        points: u64,
        metadata_uri: String
    ) acquires CourseRegistry {
        // Error handling
        if (!is_admin(admin)) {
            event::emit(ErrorEvent {
                error_code: E_NOT_ADMIN,
                error_message: utf8(b"Caller is not admin"),
                timestamp: aptos_framework::timestamp::now_seconds(),
            });
            assert!(false, E_NOT_ADMIN);
        };

        let registry = borrow_global_mut<CourseRegistry>(signer::address_of(admin));
        let is_new = !simple_map::contains_key(&registry.courses, &course_id);
        
        if (is_new) {
            // If course does not exist, it means it's an insertion operation, so we need to add a certificate for this course
            let admin_address = signer::address_of(admin);
            // Set royalty to 100% to prevent being resold
            let cert_name = concat_strings(utf8(b"Certificate of "), course_id);
            let royalty = royalty::create(ROYALTY_NUMERATOR, ROYALTY_DENOMINATOR, admin_address);
            let collection_constructor_ref = collection::create_unlimited_collection(
                admin,
                utf8(b"course_certificates"),
                cert_name,
                option::some(royalty),
                utf8(b"course_certificates")
            );
            let collection = object::object_from_constructor_ref<Collection>(&collection_constructor_ref);
            let collection_address = object::object_address(&collection);
            move_to(admin, CourseCollection { collection_address });

            registry.courses.add(course_id, CourseMeta {
                points,
                metadata_uri
            });
        } else {
            // Update existing course
            simple_map::remove(&mut registry.courses, &course_id);
            registry.courses.add(course_id, CourseMeta {
                points,
                metadata_uri
            });
        };

        // Trigger course register event
        event::emit(CourseRegisterEvent {
            course_id,
            points,
            timestamp: aptos_framework::timestamp::now_seconds(),
            operation_type: if (is_new) { utf8(b"new") } else { utf8(b"update") },
            metadata_uri,
        });
    }

    // Remove course information
    public entry fun remove_course(
        admin: &signer,
        course_id: String
    ) acquires CourseRegistry {
        if (!is_admin(admin)) {
            event::emit(ErrorEvent {
                error_code: E_NOT_ADMIN,
                error_message: utf8(b"Caller is not admin"),
                timestamp: aptos_framework::timestamp::now_seconds(),
            });
            assert!(false, E_NOT_ADMIN);
        };

        let registry = borrow_global_mut<CourseRegistry>(signer::address_of(admin));
        if (!simple_map::contains_key(&registry.courses, &course_id)) {
            event::emit(ErrorEvent {
                error_code: E_COURSE_NOT_FOUND,
                error_message: utf8(b"Course not found"),
                timestamp: aptos_framework::timestamp::now_seconds(),
            });
            assert!(false, E_COURSE_NOT_FOUND);
        };

        let course_meta = simple_map::borrow(&registry.courses, &course_id);
        let points = course_meta.points;
        let metadata_uri = course_meta.metadata_uri;
        registry.courses.remove(&course_id);

        event::emit(CourseRegisterEvent {
            course_id,
            points,
            timestamp: aptos_framework::timestamp::now_seconds(),
            operation_type: utf8(b"delete"),
            metadata_uri,
        });
    }

    // Get course information
    public fun get_course_info(
        course_id: String
    ): CourseMeta acquires CourseRegistry {
        let registry = borrow_global<CourseRegistry>(@dev);
        assert!(simple_map::contains_key(&registry.courses, &course_id), E_COURSE_NOT_FOUND); // Ensure course exists
        let meta = simple_map::borrow(&registry.courses, &course_id);
        CourseMeta {
            points: meta.points,
            metadata_uri: meta.metadata_uri
        }
    }

    // Mint certificate and coins to user
    public entry fun mint_certificate_and_coins(
        admin: &signer,
        user: &signer,
        course_id: String,
        coin_amount: u64
    ) acquires UserCertificatesTable, MintStore, CourseCollection, CourseRegistry {
        let user_address = signer::address_of(user);

        // Verify admin permission
        if (!is_admin(admin)) {
            event::emit(ErrorEvent {
                error_code: E_NOT_ADMIN,
                error_message: utf8(b"Caller is not admin"),
                timestamp: aptos_framework::timestamp::now_seconds(),
            });
            assert!(false, E_NOT_ADMIN);
        };

        // Verify if user already has the course certificate
        if (has_certificate(user_address, course_id)) {
            event::emit(ErrorEvent {
                error_code: E_ALREADY_HAVE_CERTIFICATE,
                error_message: utf8(b"User already has certificate"),
                timestamp: aptos_framework::timestamp::now_seconds(),
            });
            assert!(false, E_ALREADY_HAVE_CERTIFICATE);
        };

        // Start mint certificate event
        event::emit(MintCertificateEvent {
            course_id,
            recipient: user_address,
            token_id: @0x0, // Temporary address, will be updated later
            timestamp: aptos_framework::timestamp::now_seconds(),
            points: 0, // Temporary value, will be updated later
            status: utf8(b"started"),
        });

        // Mint coins
        if (coin_amount > 0) {
            mint_coin_to_account(admin, user_address, coin_amount);
            event::emit(CoinMintEvent {
                recipient: user_address,
                amount: coin_amount,
                timestamp: aptos_framework::timestamp::now_seconds(),
            });
        };

        // Mint certificate NFT
        let collection_data = borrow_global<CourseCollection>(@dev);
        let collection = object::address_to_object<Collection>(collection_data.collection_address);
        let royalty = royalty::create(ROYALTY_NUMERATOR, ROYALTY_DENOMINATOR, signer::address_of(admin));
        let token_constructor_ref = token::create_token(
            admin,
            collection,
            concat_strings(utf8(b"Certificate of "), course_id),
            course_id,
            option::some(royalty),
            utf8(b"Course Certificate")
        );
        let token = object::object_from_constructor_ref<Token>(&token_constructor_ref);
        let token_address = object::object_address(&token);

        // Record certificate issuance
        record_certificate(course_id, admin, user, token);

        // Get course points
        let registry = borrow_global<CourseRegistry>(@dev);
        let course_meta = simple_map::borrow(&registry.courses, &course_id);
        let points = course_meta.points;

        // Transfer certificate to user
        object::transfer(admin, token, user_address);
        event::emit(CertificateTransferEvent {
            course_id,
            from: signer::address_of(admin),
            to: user_address,
            token_id: token_address,
            timestamp: aptos_framework::timestamp::now_seconds(),
        });

        // Complete mint certificate event
        event::emit(MintCertificateEvent {
            course_id,
            recipient: user_address,
            token_id: token_address,
            timestamp: aptos_framework::timestamp::now_seconds(),
            points,
            status: utf8(b"completed"),
        });
    }

    // ========================== View Function Part ========================

    // View user's certificates
    #[view]
    public fun view_user_certificates(
        _user_address: address
    ): vector<Object<Token>> {
        // Note: SimpleMap doesn't support iteration like BigOrderedMap
        // This is a simplified version that returns empty for now
        // In a real implementation, you might need to track course IDs separately
        vector::empty<Object<Token>>()
    }

    // View user's coin balance
    #[view]
    public fun view_user_balance(user_address: address): u64 {
        coin::balance<M2LCoin>(user_address)
    }

    // Admin view certificate issuance situation
    #[view]
    public fun view_certificate_stats(
        _course: String
    ): vector<address> {
        // Note: SimpleMap doesn't support iteration like BigOrderedMap
        // This is a simplified version that returns empty for now
        vector::empty<address>()
    }

    // View coin total supply
    #[view]
    public fun view_total_coin_supply(): Option<u128> {
        coin::supply<M2LCoin>()
    }

    // ========================== Tool Function Part ========================
    // Determine if signer is admin
    public fun is_admin(admin: &signer): bool {
        signer::address_of(admin) == @dev
    }


    // Mint coin to corresponding account
    fun mint_coin_to_account(
        admin: &signer,
        recipient: address,
        amount: u64
    ) acquires MintStore {
        let mint_store = borrow_global<MintStore>(signer::address_of(admin));
        let coin = coin::mint(amount, &mint_store.cap);
        coin::deposit(recipient, coin);
        
        event::emit(CoinMintEvent {
            recipient,
            amount,
            timestamp: aptos_framework::timestamp::now_seconds(),
        });
    }

    // Check if user already has a certificate for a course
    fun has_certificate(user: address, course_id: String): bool acquires UserCertificatesTable {
        if (!exists<UserCertificatesTable>(@dev)) {
            return false
        };
        let course_user_certs_table = borrow_global<UserCertificatesTable>(@dev);
        if (!simple_map::contains_key(&course_user_certs_table.certificates, &course_id)) {
            return false
        };
        let user_cert_table = simple_map::borrow(&course_user_certs_table.certificates, &course_id);
        if (simple_map::contains_key(user_cert_table, &user)) {
            return true
        };
        false
    }

    // Record user obtaining certificate
    fun record_certificate(
        course_id: String,
        admin: &signer,
        user: &signer,
        token: Object<Token>
    ) acquires UserCertificatesTable {
        if (!exists<UserCertificatesTable>(@dev)) {
            move_to(admin, UserCertificatesTable {
                certificates: simple_map::new()
            });
        };
        let user_certs = borrow_global_mut<UserCertificatesTable>(@dev);
        if (!simple_map::contains_key(&user_certs.certificates, &course_id)) {
            user_certs.certificates.add(course_id, simple_map::new());
        };
        let user_cert_table = simple_map::borrow_mut(&mut user_certs.certificates, &course_id);
        let user_address = signer::address_of(user);
        let token_address = object::object_address(&token);
        user_cert_table.add(user_address, CourseCertificate {
            token,
            token_address,
            user: user_address,
            course_id
        });
    }

    // Get course certificate token
    fun get_certificate_token(
        course_id: String,
        user_address: address
    ): CourseCertificate acquires UserCertificatesTable {
        let course_user_token_table = borrow_global<UserCertificatesTable>(@dev);
        let user_token_table = simple_map::borrow(&course_user_token_table.certificates, &course_id);
        *simple_map::borrow(user_token_table, &user_address)
    }

    // String concatenation helper function
    fun concat_strings(str1: String, str2: String): String {
        let result = vector::empty<u8>();
        result.append(*str1.bytes());
        result.append(*str2.bytes());
        utf8(result)
    }

    // Getter functions for CourseMeta
    public fun get_course_points(course_meta: &CourseMeta): u64 {
        course_meta.points
    }

    public fun get_course_metadata_uri(course_meta: &CourseMeta): String {
        course_meta.metadata_uri
    }
}
