// 证书签发模块
module dev::certificate {

    use std::option;
    use std::option::Option;
    use std::signer;
    use std::string::{utf8, String};
    use std::vector;
    use aptos_std::big_ordered_map;
    use aptos_std::big_ordered_map::BigOrderedMap;
    use aptos_std::table;
    use aptos_std::table::Table;
    use aptos_framework::coin;
    use aptos_framework::event;
    use aptos_framework::object;
    use aptos_framework::object::{ConstructorRef, Object};
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
        courses: BigOrderedMap<String, CourseMeta>
    }

    // 课程证书集合
    struct CourseCollection has store {
        inner: ConstructorRef,
    }

    // 课程证书NFT
    struct CourseCertificate has key, store {
        token: Object<token::Token>,
        token_address: address,
        user: address,
        course_id: String
    }

    // 用户证书记录表
    struct UserCertificatesTable has key {
        certificates: Table<String, Table<address, CourseCertificate>> // course_id ->  user_id -> CourseCertificate
    }


    // 铸造证书事件
    #[event]
    struct MintCertificateEvent has drop, store {
        course_id: String,
        recipient: address,
        token_id: address,
        timestamp: u64,
        points: u64,
        status: String, // started/completed
    }

    // 课程注册事件
    #[event]
    struct CourseRegisterEvent has drop, store {
        course_id: String,
        points: u64,
        timestamp: u64,
        operation_type: String, // new/update/delete
        metadata_uri: String,
    }

    // 代币铸造事件
    #[event]
    struct CoinMintEvent has drop, store {
        recipient: address,
        amount: u64,
        timestamp: u64,
    }

    // 证书转移事件
    #[event]
    struct CertificateTransferEvent has drop, store {
        course_id: String,
        from: address,
        to: address,
        token_id: address,
        timestamp: u64,
    }

    // 错误事件
    #[event]
    struct ErrorEvent has drop, store {
        error_code: u64,
        error_message: String,
        timestamp: u64,
    }

    // ================= 合约交互部分 ====================
    // 初始化合约
    public entry fun initialize(admin: &signer) {
        assert!(is_admin(admin), E_NOT_ADMIN);
        move_to(admin, CourseRegistry {
            courses: big_ordered_map::new()
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
    }

    // 注册/更新课程
    public entry fun set_course(
        admin: &signer,
        course_id: String,
        points: u64,
        metadata_uri: String
    ) acquires CourseRegistry {
        // 错误处理
        if (!is_admin(admin)) {
            event::emit(ErrorEvent {
                error_code: E_NOT_ADMIN,
                error_message: utf8(b"Caller is not admin"),
                timestamp: aptos_framework::timestamp::now_seconds(),
            });
            assert!(false, E_NOT_ADMIN);
        };

        let registry = borrow_global_mut<CourseRegistry>(signer::address_of(admin));
        let is_new = !registry.courses.contains(&course_id);
        
        // 如果课程不存在，说明是插入操作，因此需要为这个课程添加证书
        if (is_new) {
            let admin_address = signer::address_of(admin);
            // 设置版税为100%，避免被转售
            let cert_name = concat_strings(utf8(b"Certificate of "), course_id);
            let royalty = royalty::create(1, 1, admin_address);
            let cert_collection = collection::create_unlimited_collection(
                admin,
                utf8(b"course_certificates"),
                cert_name,
                option::some(royalty),
                utf8(b"course_certificates")
            );
            let collection = cert_collection;
            move_to(admin, CourseCollection { inner: cert_collection });
        };

        registry.courses.upsert(course_id, CourseMeta {
            points,
            metadata_uri
        });

        // 触发课程注册事件
        event::emit(CourseRegisterEvent {
            course_id,
            points,
            timestamp: aptos_framework::timestamp::now_seconds(),
            operation_type: if (is_new) { utf8(b"new") } else { utf8(b"update") },
            metadata_uri,
        });
    }

    // 删除课程信息
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
        if (!registry.courses.contains(&course_id)) {
            event::emit(ErrorEvent {
                error_code: E_COURSE_NOT_FOUND,
                error_message: utf8(b"Course not found"),
                timestamp: aptos_framework::timestamp::now_seconds(),
            });
            assert!(false, E_COURSE_NOT_FOUND);
        };

        let course_meta = registry.courses.borrow(&course_id);
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

    // 获取课程信息
    public fun get_course_info(
        course_id: String
    ): CourseMeta acquires CourseRegistry {
        let registry = borrow_global<CourseRegistry>(@dev);
        assert!(registry.courses.contains(&course_id), E_COURSE_NOT_FOUND); // 确保课程存在
        let meta = registry.courses.borrow(&course_id);
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
    ) acquires UserCertificatesTable, MintStore, CourseCollection, CourseRegistry {
        let user_address = signer::address_of(user);

        // 验证管理员权限
        if (!is_admin(admin)) {
            event::emit(ErrorEvent {
                error_code: E_NOT_ADMIN,
                error_message: utf8(b"Caller is not admin"),
                timestamp: aptos_framework::timestamp::now_seconds(),
            });
            assert!(false, E_NOT_ADMIN);
        };

        // 验证用户是否已经拥有该课程证书
        if (has_certificate(user_address, course_id)) {
            event::emit(ErrorEvent {
                error_code: E_ALREADY_HAVE_CERTIFICATE,
                error_message: utf8(b"User already has certificate"),
                timestamp: aptos_framework::timestamp::now_seconds(),
            });
            assert!(false, E_ALREADY_HAVE_CERTIFICATE);
        };

        // 开始铸造证书事件
        event::emit(MintCertificateEvent {
            course_id: course_id,
            recipient: user_address,
            token_id: @0x0, // 临时地址，稍后更新
            timestamp: aptos_framework::timestamp::now_seconds(),
            points: 0, // 临时值，稍后更新
            status: utf8(b"started"),
        });

        // 铸造代币
        if (coin_amount > 0) {
            mint_coin_to_account(admin, user_address, coin_amount);
            event::emit(CoinMintEvent {
                recipient: user_address,
                amount: coin_amount,
                timestamp: aptos_framework::timestamp::now_seconds(),
            });
        };

        // 铸造证书NFT
        let collection = borrow_global<CourseCollection>(@dev);
        let collection_constructor_ref = collection.inner;
        let collection = object::object_from_constructor_ref<Collection>(&collection_constructor_ref);
        let token_constructor_ref = token::create_token(
            admin,
            collection,
            concat_strings(utf8(b"Certificate of "), course_id),
            course_id,
            option::some(SELL_BANNED_ROYALTY),
            utf8(b"Course Certificate")
        );
        let token = object::object_from_constructor_ref<Token>(&token_constructor_ref);
        let token_address = object::object_address(&token);

        // 记录证书发放
        record_certificate(course_id, admin, user, token);

        // 获取课程积分
        let registry = borrow_global<CourseRegistry>(@dev);
        let course_meta = registry.courses.borrow(&course_id);
        let points = course_meta.points;

        // 转移证书给用户
        object::transfer(admin, token, user_address);
        event::emit(CertificateTransferEvent {
            course_id,
            from: signer::address_of(admin),
            to: user_address,
            token_id: token_address,
            timestamp: aptos_framework::timestamp::now_seconds(),
        });

        // 完成铸造证书事件
        event::emit(MintCertificateEvent {
            course_id,
            recipient: user_address,
            token_id: token_address,
            timestamp: aptos_framework::timestamp::now_seconds(),
            points,
            status: utf8(b"completed"),
        });
    }

    // ========================== 视图函数部分 ========================

    // 查看用户拥有的证书
    public fun view_user_certificates(
        user_address: address
    ): vector<Object<Token>> acquires UserCertificatesTable, CourseRegistry {
        let user_certs = vector::empty<token::Token>();
        if (!exists<UserCertificatesTable>(@dev)) {
            return vector::empty()
        };

        let certificates = vector::empty<Object<Token>>();
        let user_certs = borrow_global<UserCertificatesTable>(@dev);
        let course_user_table = user_certs.certificates;
        let courses = borrow_global<CourseRegistry>(@dev).courses;
        let (course_id_in_loop, course_in_loop) = courses.borrow_front();
        let course_id_inl_loop = course_id_in_loop;
        while (true) {
            let next_course_id = courses.next_key(&course_id_in_loop);
            if (next_course_id.is_none()) {
                break;
            }
            else {
                if (course_user_table.contains(course_id_in_loop)) {
                    let course_table = course_user_table.borrow(course_id_in_loop);
                    if (course_table.contains(user_address)) {
                        let course_cert = course_table.borrow(user_address);
                        let token_address = course_cert.token_address;
                        let token = object::address_to_object<Token>(token_address);
                        certificates.push_back(token);
                    }
                };
                course_id_in_loop = *next_course_id.borrow()
            }
        };
        certificates
    }

    // 查看用户的代币余额
    public fun view_user_balance(user_address: address): u64 {
        coin::balance<M2LCoin>(user_address)
    }

    // 管理员查看证书发放情况
    public fun view_certificate_stats(
        admin: &signer,
        course: String
    ): Table<address, CourseCertificate> acquires UserCertificatesTable, CourseCertificate {
        assert!(is_admin(admin), E_NOT_ADMIN);
        if (!exists<UserCertificatesTable>(@dev)) {
            let stats = table::new<address, CourseCertificate>();
            return stats
        };
        let user_certs = borrow_global<UserCertificatesTable>(@dev);
        let courses = user_certs.certificates.borrow(course);
        return *courses
    }

    // 管理员查看代币总量
    public fun view_total_coin_supply(admin: &signer): Option<u128> {
        assert!(is_admin(admin), E_NOT_ADMIN);
        coin::supply<M2LCoin>()
    }

    // ========================== 工具函数部分 ========================
    // 确定signer是否是管理员
    public fun is_admin(admin: &signer): bool {
        signer::address_of(admin) == @dev
    }


    // 铸造coin到对应的账户
    fun mint_coin_to_account(
        admin: &signer,
        recipient: address,
        amount: u64
    ) acquires MintStore {
        let mint_cap = borrow_global<MintStore>(signer::address_of(admin)).cap;
        let coin = coin::mint(amount, &mint_cap);
        coin::deposit(recipient, coin);
        
        event::emit(CoinMintEvent {
            recipient,
            amount,
            timestamp: aptos_framework::timestamp::now_seconds(),
        });
    }

    // 检查用户是否已经拥有某个课程的证书
    fun has_certificate(user: address, course_id: String): bool acquires UserCertificatesTable {
        if (!exists<UserCertificatesTable>(@dev)) {
            return false
        };
        let course_user_certs_table = borrow_global<UserCertificatesTable>(@dev);
        if (!course_user_certs_table.certificates.contains(course_id)) {
            return false
        };
        let user_cert_table = course_user_certs_table.certificates.borrow(course_id);
        if (user_cert_table.contains(user)) {
            return true
        };
        false
    }

    // 记录用户获得证书
    fun record_certificate(
        course_id: String,
        admin: &signer,
        user: &signer,
        token: Object<Token>
    ) acquires UserCertificatesTable {
        if (!exists<UserCertificatesTable>(@dev)) {
            move_to(admin, UserCertificatesTable {
                certificates: table::new()
            });
        };
        let user_certs = borrow_global_mut<UserCertificatesTable>(@dev);
        if (!user_certs.certificates.contains(course_id)) {
            user_certs.certificates.add(course_id, table::new());
        };
        let user_cert_table = user_certs.certificates.borrow_mut(course_id);
        let user_address = signer::address_of(user);
        let token_address = object::object_address(&token);
        user_cert_table.add(user_address, CourseCertificate {
            token,
            token_address,
            user: user_address,
            course_id
        });
    }

    // 获取课程证书token
    fun get_certificate_token(
        course_id: String,
        user_address: address
    ): CourseCertificate acquires UserCertificatesTable {
        let course_user_token_table = borrow_global_mut<UserCertificatesTable>(@dev);
        let user_token_table = course_user_token_table.certificates.borrow_mut(course_id);
        let user_token = user_token_table.borrow(user_address);
        *user_token
    }

    // 字符串拼接辅助函数
    fun concat_strings(str1: String, str2: String): String {
        let result = vector::empty<u8>();
        result.append(*str1.bytes());
        result.append(*str2.bytes());
        utf8(result)
    }
}
