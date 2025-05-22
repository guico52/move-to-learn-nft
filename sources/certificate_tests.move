#[test_only]
module dev::certificate_tests {
    use std::option;
    use std::string::{utf8};
    use std::signer;
    use std::vector;
    use aptos_std::table;
    use aptos_framework::account;
    use aptos_framework::coin;
    use aptos_framework::timestamp;
    use aptos_framework::object;
    use aptos_token_objects::token::Token;
    use dev::certificate::{Self, M2LCoin};

    // Test constants
    const ADMIN_ADDR: address = @dev;
    const USER_ADDR: address = @0x123;
    
    // Initialize test environment
    fun setup_test(aptos_framework: &signer): (signer, signer) {
        // Create test accounts
        let admin = account::create_account_for_test(ADMIN_ADDR);
        let user = account::create_account_for_test(USER_ADDR);
        
        // Initialize timestamp
        timestamp::set_time_has_started_for_testing(aptos_framework);
        
        (admin, user)
    }

    #[test]
    fun test_initialize_contract() {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        let (admin, _) = setup_test(&aptos_framework);
        
        // Initialize contract
        certificate::initialize(&admin);
        
        // Verify admin identity
        assert!(certificate::is_admin(&admin), 0);
    }

    #[test]
    fun test_course_management() {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        let (admin, _) = setup_test(&aptos_framework);
        
        // Initialize contract
        certificate::initialize(&admin);
        
        // Add course
        let course_id = utf8(b"course_001");
        let points = 100;
        let metadata_uri = utf8(b"https://example.com/course/001");
        certificate::set_course(&admin, course_id, points, metadata_uri);
        
        // Verify course information
        let course_info = certificate::get_course_info(course_id);
        assert!(course_info.points == points, 1);
        assert!(course_info.metadata_uri == metadata_uri, 2);
    }

    #[test]
    fun test_mint_certificate_and_coins() {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        let (admin, user) = setup_test(&aptos_framework);
        
        // Initialize contract
        certificate::initialize(&admin);
        
        // Add course
        let course_id = utf8(b"course_001");
        let points = 100;
        let metadata_uri = utf8(b"https://example.com/course/001");
        certificate::set_course(&admin, course_id, points, metadata_uri);
        
        // Mint certificate and coins
        let coin_amount = 50;
        certificate::mint_certificate_and_coins(&admin, &user, course_id, coin_amount);
        
        // Verify user coin balance
        let balance = certificate::view_user_balance(USER_ADDR);
        assert!(balance == coin_amount, 3);
        
        // Verify user certificates
        let certificates = certificate::view_user_certificates(USER_ADDR);
        assert!(!certificates.is_empty(), 4);
    }

    #[test]
    #[expected_failure(abort_code = certificate::E_ALREADY_HAVE_CERTIFICATE)]
    fun test_duplicate_certificate_mint() {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        let (admin, user) = setup_test(&aptos_framework);
        
        // Initialize contract
        certificate::initialize(&admin);
        
        // Add course
        let course_id = utf8(b"course_001");
        certificate::set_course(&admin, course_id, 100, utf8(b"https://example.com/course/001"));
        
        // First certificate mint
        certificate::mint_certificate_and_coins(&admin, &user, course_id, 50);
        
        // Try to mint duplicate certificate (should fail)
        certificate::mint_certificate_and_coins(&admin, &user, course_id, 50);
    }

    #[test]
    #[expected_failure(abort_code = certificate::E_NOT_ADMIN)]
    fun test_unauthorized_course_creation() {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        let (admin, user) = setup_test(&aptos_framework);
        
        // Initialize contract
        certificate::initialize(&admin);
        
        // Non-admin tries to add course (should fail)
        certificate::set_course(&user, utf8(b"course_001"), 100, utf8(b"https://example.com/course/001"));
    }

    #[test]
    fun test_view_functions() {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        let (admin, user) = setup_test(&aptos_framework);
        
        // Initialize contract
        certificate::initialize(&admin);
        
        // Add course and mint certificate
        let course_id = utf8(b"course_001");
        certificate::set_course(&admin, course_id, 100, utf8(b"https://example.com/course/001"));
        certificate::mint_certificate_and_coins(&admin, &user, course_id, 50);
        
        // Test view functions
        let total_supply = certificate::view_total_coin_supply(&admin);
        assert!(total_supply.is_some(), 5);
        
        let stats = certificate::view_certificate_stats(&admin, course_id);
        assert!(stats.contains(USER_ADDR), 6);
        
        let balance = certificate::view_user_balance(USER_ADDR);
        assert!(balance == 50, 7);
    }
} 