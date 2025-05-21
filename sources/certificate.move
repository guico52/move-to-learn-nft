// 证书签发模块
module dev::certificate {

    use std::option;
    use std::signer;
    use std::string::{utf8, String};
    use std::vector;
    use aptos_std::debug;
    use aptos_std::table;
    use aptos_std::table::Table;
    use aptos_framework::coin;
    use aptos_framework::object;
    use aptos_framework::object::ConstructorRef;
    use aptos_token_objects::token::Token;
    use aptos_token_objects::collection::Collection;
    use aptos_token_objects::royalty;
    use aptos_token_objects::token;
    use aptos_token_objects::collection;
    use aptos_token_objects::royalty::{Royalty};

    // 定义错误码
    const E_NOT_ADMIN: u64 = 1;
    // 调用者非管理员
    const E_ALREADY_CLAIMED: u64 = 2;
    // 课程已被领取
    const E_INSUFFICIENT_BALANCE: u64 = 3;
    // 余额不足
    const E_COURSE_NOT_EXISTS: u64 = 4;
    // 课程不存在
    const E_ALREADY_HAVE_CERTIFICATE: u64 = 5;
    // 已经拥有证书
    const E_COURSE_ALREADY_EXISTS: u64 = 6;
    // 课程已存在
    const E_COURSE_NOT_FOUND: u64 = 7; // 课程不存在

    const ADMIN_ADDRESS: address = @dev; // 管理员地址

    const SELL_BANNED_ROYALTY: Royalty = royalty::create(1, 1, @dev);
    // 定义一些类型

    // 用户积分系统及其能力
    struct M2LCoin has store {}

    struct MintStore has key { cap: coin::MintCapability<M2LCoin> }

    struct BurnStore has key { cap: coin::BurnCapability<M2LCoin> }

    struct FreezeStore has key { cap: coin::FreezeCapability<M2LCoin> }

    // 课程元数据结构
    struct CourseMeta has store {
        points: u64,
        metadata_uri: String,
    }

    // 课程注册表
    struct CourseRegistry has key {
        courses: Table<String, CourseMeta>
    }

    // 课程证书集合
    struct CourseCollection has store {
        inner: ConstructorRef,
    }

    // 课程证书NFT
    struct CourseCertificate has key, store {
        token: token::Token
    }

    // 用户证书记录表
    struct UserCertificates has key {
        certificates: Table<String, vector<address>> // course_id -> user addresses
    }

    // ================= 合约交互部分 ====================
    // 初始化合约
    public entry fun initialize(admin: &signer) {
        assert!(is_admin(admin), E_NOT_ADMIN);
        move_to(admin, CourseRegistry {
            courses: table::new()
        });
        let coin_name = utf8(b"m2l_coin");
        let coin_symbol = utf8(b"m2l");
        // 注册coin
        let (burn, freeze, mint) =
            coin::initialize<M2LCoin>(admin, coin_name, coin_symbol, 8, false);
        // 存储coin的mint, burn, freeze能力
        move_to(admin, MintStore { cap: mint });
        move_to(admin, BurnStore { cap: burn });
        move_to(admin, FreezeStore { cap: freeze });
        // 注册课程证书集合
        let admin_address = signer::address_of(admin);
        // 设置版税为100%，避免被转售
        let royalty = royalty::create(1, 1, admin_address);
        let cert_collection = collection::create_unlimited_collection(
            admin,
            utf8(b"course_certificates"),
            utf8(b"course_certificates"),
            option::some(royalty),
            utf8(b"course_certificates")
        );
        let collection = cert_collection;
        move_to(admin, CourseCollection { inner: cert_collection });
    }

    // 注册/更新课程
    public entry fun set_course(
        admin: &signer,
        course_id: String,
        points: u64,
        metadata_uri: String
    ) acquires CourseRegistry {
        assert!(is_admin(admin), E_NOT_ADMIN); // 确保调用者是管理员
        let registry = borrow_global_mut<CourseRegistry>(signer::address_of(admin));
        assert!(!registry.courses.contains(course_id), E_COURSE_ALREADY_EXISTS); // 确保课程不存在
        registry.courses.upsert(course_id, CourseMeta {
            points,
            metadata_uri
        });
    }

    // 删除课程信息
    public entry fun remove_course(
        admin: &signer,
        course_id: String
    ) acquires CourseRegistry {
        assert!(is_admin(admin), E_NOT_ADMIN); // 确保调用者是管理员
        let registry = borrow_global_mut<CourseRegistry>(signer::address_of(admin));
        assert!(registry.courses.contains(course_id), E_COURSE_NOT_FOUND); // 确保课程存在
        registry.courses.remove(course_id)
    }

    // 获取课程信息
    public fun get_course_info(
        course_id: String
    ): CourseMeta acquires CourseRegistry {
        let registry = borrow_global<CourseRegistry>(@dev);
        assert!(registry.courses.contains(course_id), E_COURSE_NOT_FOUND); // 确保课程存在
        let meta = registry.courses.borrow(course_id);
        CourseMeta {
            points: meta.points,
            metadata_uri: meta.metadata_uri
        }
    }

    // 铸造证书和代币给用户
    public entry fun mint_certificate_and_coins(
        admin: &signer,
        user: &signer,
        course_id: String,
        coin_amount: u64
    ) acquires UserCertificates, MintStore, CourseCollection {
        // 验证管理员权限
        assert!(is_admin(admin), E_NOT_ADMIN);
        // 验证用户是否已经拥有该课程证书
        let user_address = signer::address_of(user);
        assert!(!has_certificate(user_address, course_id), E_ALREADY_HAVE_CERTIFICATE);
        // 铸造代币
        if (coin_amount > 0) {
            mint_coin_to_account(admin, user_address, coin_amount);
        };
        // 铸造证书NFT
        let collection = borrow_global<CourseCollection>(@dev);
        let collection_constructor_ref = collection.inner;
        let collection = object::object_from_constructor_ref<Collection>(&collection_constructor_ref);
        let token = token::create_token(
            admin,
            collection,
            concat_strings(utf8(b"Certificate of "), course_id),
            course_id,
            option::some(SELL_BANNED_ROYALTY),
            utf8(b"Course Certificate")
        );

        // 记录证书发放
        record_certificate(course_id, admin, user);
        // 转移证书给用户
        object::transfer(admin, collection, user_address);
        debug::print(&utf8(b"Certificate minted and coins sent to user"));
    }

    // ========================== 视图函数部分 ========================

    // 获取用户的证书列表
    public fun get_user_certificates(user: address): vector<Token> acquires UserCertificates {
        if (!exists<UserCertificates>(@dev)) {
            return vector::empty();
        };
        let user_certs = borrow_global<UserCertificates>(@dev);

    }

    // ========================== 工具函数部分 ========================
    // 确定signer是否是管理员
    public fun is_admin(admin: &signer): bool {
        signer::address_of(admin) == @dev
    }


    // 铸造coin到对应的账户
    // admin账户需要预检查，此函数不做检查
    fun mint_coin_to_account(
        admin: &signer,
        recipient: address,
        amount: u64
    ) acquires MintStore {
        let mint_cap = borrow_global<MintStore>(signer::address_of(admin)).cap;
        let coin = coin::mint(amount, &mint_cap);
        coin::deposit(recipient, coin);
    }

    // 检查用户是否已经拥有某个课程的证书
    fun has_certificate(user: address, course_id: String): bool acquires UserCertificates {
        if (!exists<UserCertificates>(@dev)) {
            return false
        };
        let user_certs = borrow_global<UserCertificates>(@dev);
        if (!user_certs.certificates.contains(course_id)) {
            return false
        };
        let holders = user_certs.certificates.borrow(course_id);
        holders.contains(&user)
    }

    // 记录用户获得证书
    fun record_certificate(course_id: String, admin: &signer, user: &signer) acquires UserCertificates {
        if (!exists<UserCertificates>(@dev)) {
            move_to(admin, UserCertificates {
                certificates: table::new()
            });
        };
        let user_certs = borrow_global_mut<UserCertificates>(@dev);
        if (!user_certs.certificates.contains(course_id)) {
            user_certs.certificates.add(course_id, vector::empty());
        };
        let holders = user_certs.certificates.borrow_mut(course_id);
        let user_address = signer::address_of(user);
        holders.push_back(user_address);
    }

    // 字符串拼接辅助函数
    fun concat_strings(str1: String, str2: String): String {
        let result = vector::empty<u8>();
        result.append(*str1.bytes());
        result.append(*str2.bytes());
        utf8(result)
    }


}
