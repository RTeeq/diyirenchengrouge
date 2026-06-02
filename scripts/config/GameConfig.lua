-- ============================================================================
-- GameConfig.lua — 全局配置
-- ============================================================================

local GameConfig = {}

-- ----------------------------------------------------------------------------
-- 游戏基本信息
-- ----------------------------------------------------------------------------
GameConfig.Title = ""
GameConfig.Version = "0.1.0"

-- ----------------------------------------------------------------------------
-- 玩家控制
-- ----------------------------------------------------------------------------
GameConfig.Player = {
    MoveSpeed       = 10,        -- 移动速度 cm/s（正常步行）
    SprintMultiplier = 1.6,      -- 冲刺倍率（冲刺 = 8 m/s）
    MouseSensitivity = 0.15,     -- 鼠标灵敏度
    EyeHeight       = 1.6,       -- 视点高度 m
    InteractDistance = 3.0,       -- 交互距离 m
    PitchMin        = -80.0,     -- 俯仰下限
    PitchMax        = 80.0,      -- 俯仰上限
    Gravity         = -9.81,     -- 重力
    JumpSpeed       = 7.0,       -- 跳跃初速度 m/s
    StartPosition   = { x = 0, y = 1.6, z = -8 },  -- 出生位置
    -- 物理参数
    Mass            = 80.0,      -- 玩家质量 kg
    LinearDamping   = 0.4,       -- 线性阻尼（模拟地面摩擦）

    CapsuleRadius   = 0.4,       -- 胶囊碰撞体半径
    CapsuleHeight   = 1.6,       -- 胶囊碰撞体高度

    -- 闪现（双击 Shift）
    DashDistance     = 8.0,      -- 闪现距离 m
    DashCooldown    = 0.5,       -- 闪现冷却 s（连续闪现最小间隔）
    DashDoubleTap   = 0.3,       -- 双击判定窗口 s
    DashStaminaCost = 20,        -- 每次闪现消耗体力
    DashStaminaMax  = 100,       -- 闪现体力上限
    DashStaminaRegen = 10,       -- 体力每秒恢复量
    DashInvDuration = 0.2,       -- 闪现无敌帧持续时间 s
    DashMaxCharges  = 5,         -- 最大闪现次数（= Max / Cost）

    -- 剑道组合技（Shift+右键蓄力）
    -- 组合技通用
    ComboChargeTime = 1.5,        -- 蓄力时间 s（所有组合技共享）

    -- Shift+W+RMB: 剑道冲刺
    ComboSwordPath = {
        SlashLength     = 30.0,   -- 剑道长度 m
        SlashWidth      = 3.0,    -- 剑道宽度 m
        SlashDuration   = 6.0,    -- 剑道持续时间 s
        SlashTickRate   = 0.3,    -- 伤害间隔 s
        SlashDamage     = 15,     -- 每次 tick 伤害
        FreezeDuration  = 5.0,    -- 控制时间 s
        RushDistance     = 30.0,  -- 冲击位移 m
    },

    -- Shift+A+RMB: 冰封横扫（半圆）
    ComboIceSweep = {
        Radius          = 15.0,   -- 半圆半径 m
        Duration        = 6.0,    -- 剑道持续时间 s
        TickRate        = 0.3,    -- 伤害间隔 s
        Damage          = 12,     -- 每次 tick 伤害（剑伤+冻伤）
        FreezeDuration  = 5.0,    -- 控制（冻结）时间 s
        SlowDuration    = 20.0,   -- 减速持续 s
        Color           = { r=0.3, g=0.6, b=1.0 },  -- 冰蓝
    },

    -- Shift+D+RMB: 烈焰横扫（半圆）
    ComboFireSweep = {
        Radius          = 15.0,   -- 半圆半径 m
        Duration        = 6.0,    -- 剑道持续时间 s
        TickRate        = 0.3,    -- 伤害间隔 s
        Damage          = 12,     -- 每次 tick 伤害（剑伤）
        FreezeDuration  = 5.0,    -- 控制时间 s
        BurnDuration    = 20.0,   -- 火焰DOT持续 s
        BurnDPS         = 5,      -- 火焰每秒伤害
        Color           = { r=1.0, g=0.4, b=0.1 },  -- 烈焰橙
    },

    -- Shift+S+RMB: 风遁（全圆）
    ComboWindRelease = {
        Radius          = 20.0,   -- 圆形半径 m
        Duration        = 3.0,    -- 风遁可视持续 s
        LaunchHeight    = 25.0,   -- 击飞高度 m
        FallDamage      = 80,     -- 掉落伤害
        Color           = { r=0.5, g=1.0, b=0.6 },  -- 风绿
    },
}

-- ----------------------------------------------------------------------------
-- 相机
-- ----------------------------------------------------------------------------
GameConfig.Camera = {
    FOV      = 70.0,
    NearClip = 0.1,
    FarClip  = 1000.0,
}

-- ----------------------------------------------------------------------------
-- 三渲二配色方案（高饱和、暖色调）
-- 灵感来源：蜡笔小新煤炭镇/Ooblets
-- ----------------------------------------------------------------------------
GameConfig.Colors = {
    -- 地面/自然
    Grass       = Color(0.42, 0.65, 0.32, 1.0),   -- 草地绿
    DirtPath    = Color(0.72, 0.58, 0.40, 1.0),   -- 土路棕
    Water       = Color(0.30, 0.55, 0.78, 1.0),   -- 河水蓝
    TreeTrunk   = Color(0.45, 0.30, 0.18, 1.0),   -- 树干棕
    TreeLeaves  = Color(0.35, 0.60, 0.25, 1.0),   -- 树叶绿
    DarkLeaves  = Color(0.22, 0.45, 0.18, 1.0),   -- 深叶绿
    Rock        = Color(0.55, 0.53, 0.50, 1.0),   -- 岩石灰

    -- 建筑
    WallWhite   = Color(0.92, 0.90, 0.85, 1.0),   -- 白墙
    WallYellow  = Color(0.90, 0.78, 0.50, 1.0),   -- 黄墙
    WallOrange  = Color(0.88, 0.60, 0.35, 1.0),   -- 橙墙
    WallPink    = Color(0.90, 0.72, 0.70, 1.0),   -- 粉墙
    RoofRed     = Color(0.72, 0.28, 0.18, 1.0),   -- 红瓦屋顶
    RoofBrown   = Color(0.55, 0.38, 0.25, 1.0),   -- 棕瓦屋顶
    RoofGray    = Color(0.45, 0.42, 0.40, 1.0),   -- 灰瓦屋顶
    WoodDoor    = Color(0.50, 0.35, 0.20, 1.0),   -- 木门
    WoodFence   = Color(0.60, 0.45, 0.28, 1.0),   -- 篱笆

    -- 特殊
    Bridge      = Color(0.58, 0.42, 0.25, 1.0),   -- 桥梁木色
    Lantern     = Color(0.85, 0.25, 0.15, 1.0),   -- 灯笼红
    Stone       = Color(0.62, 0.60, 0.55, 1.0),   -- 石板
    Temple      = Color(0.80, 0.70, 0.50, 1.0),   -- 庙宇金
    SkyBlue     = Color(0.55, 0.78, 0.95, 1.0),   -- 天空蓝
}

-- ----------------------------------------------------------------------------
-- PBR 材质参数（三渲二 = 高粗糙度 + 无金属感）
-- ----------------------------------------------------------------------------
GameConfig.Material = {
    DefaultRoughness = 0.92,
    DefaultMetallic  = 0.0,
    Technique        = "Techniques/PBR/PBRNoTexture.xml",
    TechniqueAlpha   = "Techniques/PBR/PBRNoTextureAlpha.xml",
}

-- ----------------------------------------------------------------------------
-- 战斗系统
-- ----------------------------------------------------------------------------
GameConfig.Combat = {
    PlayerMaxHP         = 100,
    PlayerAttackDamage  = 25,
    PlayerAttackRange   = 3.5,
    PlayerAttackCooldown = 0.5,
    InvincibilityTime   = 1.0,
}

GameConfig.Enemies = {
    Melee = {
        HP            = 60,
        Damage        = 15,
        AttackRange   = 2.5,
        DetectRange   = 12.0,
        ChaseSpeed    = 3.0,
        PatrolSpeed   = 1.5,
        AttackCooldown = 1.5,
        BodyColor     = Color(0.35, 0.12, 0.45, 1.0),
        HeadColor     = Color(0.25, 0.08, 0.35, 1.0),
    },
    Ranged = {
        HP              = 35,
        Damage          = 10,
        AttackRange     = 15.0,
        DetectRange     = 18.0,
        RetreatRange    = 6.0,
        MoveSpeed       = 2.0,
        AttackCooldown  = 2.5,
        ProjectileSpeed = 10.0,
        BodyColor       = Color(0.12, 0.30, 0.25, 1.0),
        HeadColor       = Color(0.2, 0.9, 0.5, 1.0),
    },
    Boss = {
        HP              = 500,
        Damage          = 30,
        AttackRange     = 3.5,
        DetectRange     = 25.0,
        ChaseSpeed      = 2.5,
        PatrolSpeed     = 1.0,
        AttackCooldown  = 2.0,
        BodyColor       = Color(0.6, 0.1, 0.1, 1.0),
        HeadColor       = Color(1.0, 0.2, 0.05, 1.0),
        Scale           = 2.0,   -- Boss 体型倍率
    },
    -- 精英近战 (升级后解锁)
    EliteMelee = {
        HP            = 120,
        Damage        = 25,
        AttackRange   = 3.0,
        DetectRange   = 15.0,
        ChaseSpeed    = 4.0,
        PatrolSpeed   = 2.0,
        AttackCooldown = 1.2,
        BodyColor     = Color(0.60, 0.15, 0.10, 1.0),  -- 深红
        HeadColor     = Color(0.80, 0.20, 0.10, 1.0),
    },
    -- 精英远程 (升级后解锁)
    EliteRanged = {
        HP              = 70,
        Damage          = 18,
        AttackRange     = 20.0,
        DetectRange     = 22.0,
        RetreatRange    = 8.0,
        MoveSpeed       = 2.8,
        AttackCooldown  = 2.0,
        ProjectileSpeed = 14.0,
        BodyColor       = Color(0.20, 0.10, 0.40, 1.0),  -- 深紫
        HeadColor       = Color(0.6, 0.3, 1.0, 1.0),
    },
    -- 精英AOE — 炼狱术士（10分钟解锁）
    EliteAOE = {
        HP              = 150,
        Damage          = 12,
        AOERange        = 5.0,     -- 地面冲击波范围
        AOECooldown     = 3.0,     -- 冲击波冷却
        DetectRange     = 16.0,
        ChaseSpeed      = 2.5,
        PatrolSpeed     = 1.5,
        AttackRange     = 5.0,     -- 到位即释放AOE
        AttackCooldown  = 3.0,
        BodyColor       = Color(0.70, 0.25, 0.08, 1.0),  -- 橙红
        HeadColor       = Color(1.0, 0.50, 0.10, 1.0),   -- 亮橙
        GlowColor       = Color(1.0, 0.40, 0.05, 1.0),   -- 火焰橙
    },
    -- 精英Debuff — 瘟疫幽魂（15分钟解锁）
    EliteDebuff = {
        HP              = 100,
        Damage          = 8,
        SlowMult        = 0.5,     -- 减速50%
        SlowDuration    = 3.0,
        BurnDPS         = 3,       -- 灼烧每秒伤害
        BurnDuration    = 4.0,
        DetectRange     = 18.0,
        RetreatRange    = 8.0,     -- 保持距离
        MoveSpeed       = 2.8,
        AttackRange     = 14.0,
        AttackCooldown  = 2.5,
        ProjectileSpeed = 12.0,
        BodyColor       = Color(0.15, 0.35, 0.12, 1.0),  -- 暗绿
        HeadColor       = Color(0.30, 0.90, 0.20, 1.0),  -- 毒绿
        GlowColor       = Color(0.20, 0.80, 0.10, 1.0),  -- 荧光绿
    },
    -- 挑战龙Boss（每10级触发）
    DragonBoss = {
        HP              = 800,
        Damage          = 40,
        AttackRange     = 5.0,     -- 俯冲攻击范围
        DetectRange     = 50.0,    -- 超远感知
        FlySpeed        = 6.0,     -- 飞行速度
        DiveSpeed       = 12.0,    -- 俯冲速度
        FlyHeight       = 12.0,    -- 飞行高度
        CircleRadius    = 15.0,    -- 盘旋半径
        DiveCooldown    = 6.0,     -- 俯冲间隔
        BreathCooldown  = 3.0,     -- 吐息间隔
        BreathDamage    = 15,      -- 火焰吐息伤害
        BreathSpeed     = 14.0,    -- 吐息弹速
        Scale           = 2.5,     -- 体型倍率
        -- 暗黑中国龙配色
        BodyColor       = Color(0.12, 0.08, 0.18, 1.0),   -- 深紫黑
        ScaleColor      = Color(0.20, 0.10, 0.30, 1.0),   -- 鳞片暗紫
        HornColor       = Color(0.60, 0.15, 0.80, 1.0),   -- 角亮紫
        EyeColor        = Color(1.0, 0.1, 0.2, 1.0),      -- 猩红眼
        GlowColor       = Color(0.80, 0.10, 0.90, 1.0),   -- 紫色辉光
        BreathColor     = Color(0.6, 0.0, 1.0, 1.0),      -- 暗紫吐息
    },
    -- 终极Boss（每20分钟刷新）
    UltimateBoss = {
        HP              = 2000,
        Damage          = 60,
        AttackRange     = 4.0,
        DetectRange     = 60.0,
        ChaseSpeed      = 3.5,
        Scale           = 3.5,
        -- 三阶段 HP 阈值
        Phase2Threshold = 0.60,    -- 60% 进入第二阶段
        Phase3Threshold = 0.30,    -- 30% 进入第三阶段
        -- 技能参数
        StompCooldown   = 4.0,     -- 震地冲击间隔
        StompRange      = 8.0,     -- 震地范围
        StompDamage     = 35,      -- 震地伤害
        RainCooldown    = 6.0,     -- 弹幕雨间隔（P2）
        RainCount       = 8,       -- 弹幕雨数量
        RainDamage      = 20,      -- 弹幕伤害
        RainSpeed       = 10.0,    -- 弹幕速度
        TeleportCooldown = 8.0,    -- 传送间隔（P2）
        LaserCooldown   = 10.0,    -- 激光扫射间隔（P3）
        LaserDamage     = 15,      -- 激光每次伤害
        LaserDuration   = 2.0,     -- 激光持续秒数
        SummonCooldown  = 12.0,    -- 召唤小怪间隔（P3）
        SummonCount     = 3,       -- 每次召唤数量
        -- 深渊魔王配色
        BodyColor       = Color(0.08, 0.05, 0.10, 1.0),   -- 深渊黑紫
        ArmorColor      = Color(0.15, 0.08, 0.20, 1.0),   -- 暗紫铠甲
        HornColor       = Color(0.90, 0.15, 0.05, 1.0),   -- 烈焰红角
        EyeColor        = Color(1.0, 0.85, 0.0, 1.0),     -- 金黄魔眼
        GlowColor       = Color(1.0, 0.2, 0.0, 1.0),      -- 烈焰辉光
        AuraColor       = Color(0.6, 0.0, 0.0, 1.0),      -- 血红光环
    },
    -- 升级缩放
    LevelScaling = {
        HPMult          = 0.15,   -- 每级 +15% 血量
        DamageMult      = 0.10,   -- 每级 +10% 伤害
        SpeedMult       = 0.03,   -- 每级 +3% 速度
        EliteUnlockLevel = 3,     -- 3级解锁精英怪
        EliteChance     = 0.25,   -- 精英怪出现概率
        LevelBossScale  = 0.20,   -- Boss每级体型 +20%
    },
    -- 波次刷怪配置
    Wave = {
        SmallInterval   = 10.0,  -- 小波间隔（秒）
        BigInterval     = 15.0,  -- 大波间隔（秒）
        MonsterUpgrade  = 120.0, -- 怪物升级间隔（秒）= 2分钟
        BossInterval    = 300.0, -- Boss 出现间隔（秒）= 5分钟
        SpawnRadius     = { min = 20, max = 45 },
        SmallCount      = 4,     -- 小波敌人数
        BigCount        = 10,    -- 大波敌人数
        CountGrowth     = 1,     -- 每次怪物升级增加的每波人数
        CountMax        = 20,    -- 单波最大数量
        EliteAOEUnlockTime   = 600,  -- 炼狱术士解锁时间（10分钟）
        EliteDebuffUnlockTime = 900, -- 瘟疫幽魂解锁时间（15分钟）
        XPPerLevelMult  = 0.20,  -- 怪物每升一级经验 +20%
        BossRewardMult  = 10,    -- Boss 击败奖励倍率（十倍加成）
    },
}

-- ----------------------------------------------------------------------------
-- 武器系统（每个图鉴物品 = 一种武器）
-- ----------------------------------------------------------------------------
GameConfig.Weapons = {
    -- 排列顺序（图鉴顺序）
    Order = {
        "iron_sword",
        "fire_dragon_card", "peace_jade", "secret_key",
        "bagua_mirror", "exorcism_talisman", "mystery_fragment",
        "opened_scroll", "sealed_scroll", "secret_box", "holy_water",
        "thunder_drum", "shadow_fan", "blood_compass", "jade_flute", "spirit_bell",
    },
    -- 0. 铁剑 — 斩击：近战挥砍，带击退
    iron_sword = {
        name = "铁剑", icon = "🗡", skill = "斩击",
        attackType = "melee",        -- 近战类型标识
        damage = 45,
        range = 3.0,                 -- 攻击距离
        dotMin = 0.55,               -- 锥形判定（比徒手更宽）
        cooldown = 0.7,
        knockbackForce = 6.0,        -- 击退初速度 m/s
        color = Color(0.75, 0.78, 0.82, 1.0),     -- 银色钢铁
        glowColor = Color(0.4, 0.8, 1.0, 1.0),    -- 青蓝辉光
    },

    -- 1. 火龙牌 — 火球术：抛射火球，命中后爆炸
    fire_dragon_card = {
        name = "火龙牌", icon = "🔥", skill = "火球术",
        damage = 40, splashDamage = 20, splashRange = 3.0,
        speed = 15.0, cooldown = 1.5,
        color = Color(1.0, 0.4, 0.1, 1.0),
    },
    -- 2. 平安玉 — 护盾：生成 3 秒无敌护盾
    peace_jade = {
        name = "平安玉", icon = "🛡", skill = "护盾",
        duration = 3.0, cooldown = 8.0,
        color = Color(0.3, 0.9, 0.5, 1.0),
    },
    -- 3. 密钥 — 穿刺：直线穿透所有敌人
    secret_key = {
        name = "密钥", icon = "🗡", skill = "穿刺",
        damage = 30, range = 6.0, dotMin = 0.85, cooldown = 0.8,
        color = Color(0.78, 0.65, 0.20, 1.0),
    },
    -- 4. 八卦镜 — 破魔光线：远程高伤单体
    bagua_mirror = {
        name = "八卦镜", icon = "🔮", skill = "破魔光线",
        damage = 60, range = 12.0, dotMin = 0.8, cooldown = 2.0,
        color = Color(0.8, 0.6, 1.0, 1.0),
    },
    -- 5. 驱邪符 — 追踪符：自动追踪最近敌人
    exorcism_talisman = {
        name = "驱邪符", icon = "📜", skill = "追踪符",
        damage = 35, speed = 12.0, cooldown = 1.2,
        color = Color(0.90, 0.80, 0.20, 1.0),
    },
    -- 6. 神秘碎片 — 连锁闪电：连锁 3 个敌人
    mystery_fragment = {
        name = "神秘碎片", icon = "⚡", skill = "连锁闪电",
        damage = 25, range = 10.0, chainRange = 6.0, maxChains = 3,
        cooldown = 2.0,
        color = Color(0.4, 0.7, 1.0, 1.0),
    },
    -- 7. 打开的密卷 — 旋风：持续范围伤害
    opened_scroll = {
        name = "密卷", icon = "🌀", skill = "旋风",
        tickDamage = 8, range = 4.0, duration = 3.0, tickInterval = 0.5,
        cooldown = 6.0,
        color = Color(0.3, 0.8, 1.0, 1.0),
    },
    -- 8. 被封印的密卷 — 封印术：冻结范围内所有敌人
    sealed_scroll = {
        name = "封印密卷", icon = "❄", skill = "封印术",
        range = 8.0, freezeDuration = 3.0, cooldown = 10.0,
        color = Color(0.3, 0.5, 0.9, 1.0),
    },
    -- 9. 密盒 — 陷阱：放置地雷
    secret_box = {
        name = "密盒", icon = "💣", skill = "陷阱",
        damage = 50, triggerRange = 2.5, maxTraps = 3, cooldown = 3.0,
        color = Color(0.85, 0.4, 0.15, 1.0),
    },
    -- 10. 圣水 — 净化：回血 + 范围圣伤
    holy_water = {
        name = "圣水", icon = "✨", skill = "净化",
        healAmount = 50, damage = 25, range = 6.0, cooldown = 12.0,
        color = Color(0.9, 0.9, 1.0, 1.0),
    },
    -- 11. 雷鼓 — 雷霆冲击：AOE冲击波
    thunder_drum = {
        name = "雷鼓", icon = "🥁", skill = "雷霆冲击",
        damage = 45, range = 6.0, cooldown = 3.0,
        knockbackForce = 8.0,
        color = Color(0.3, 0.4, 0.9, 1.0),
        glowColor = Color(0.5, 0.6, 1.0, 1.0),
    },
    -- 12. 影扇 — 影分身：召唤影分身攻击
    shadow_fan = {
        name = "影扇", icon = "🪭", skill = "影分身",
        damage = 15, duration = 5.0, maxClones = 2, cooldown = 8.0,
        cloneSpeed = 4.0, cloneRange = 8.0,
        color = Color(0.20, 0.10, 0.30, 1.0),
        glowColor = Color(0.5, 0.2, 0.8, 1.0),
    },
    -- 13. 血罗盘 — 血域：持续伤害+减速区域
    blood_compass = {
        name = "血罗盘", icon = "🧭", skill = "血域",
        tickDamage = 5, range = 6.0, duration = 8.0, tickInterval = 1.0,
        slowPct = 0.30, cooldown = 10.0,
        color = Color(0.7, 0.1, 0.1, 1.0),
        glowColor = Color(1.0, 0.2, 0.2, 1.0),
    },
    -- 14. 翠笛 — 战歌：增益光环
    jade_flute = {
        name = "翠笛", icon = "🎵", skill = "战歌",
        atkSpdBonus = 0.25, moveSpdBonus = 0.15,
        duration = 4.0, cooldown = 15.0,
        color = Color(0.3, 0.8, 0.4, 1.0),
        glowColor = Color(0.4, 1.0, 0.5, 1.0),
    },
    -- 15. 灵铃 — 灵铃阵：环绕灵球
    spirit_bell = {
        name = "灵铃", icon = "🔔", skill = "灵铃阵",
        damage = 12, orbCount = 4, duration = 6.0,
        orbRadius = 2.5, orbSpeed = 180, cooldown = 7.0,
        color = Color(0.6, 0.8, 1.0, 1.0),
        glowColor = Color(0.7, 0.9, 1.0, 1.0),
    },
}

-- ----------------------------------------------------------------------------
-- 击杀加成配置
-- ----------------------------------------------------------------------------
GameConfig.KillBonus = {
    TierInterval    = 10,     -- 每10击杀一个层级
    BonusPerTier    = 0.02,   -- 每层级 +2%
    MaxCooldownReduction = 0.80, -- 最多减少80%冷却
    PassiveInterval = 1000,   -- 每1000击杀解锁一个被动
}

-- ----------------------------------------------------------------------------
-- 游戏状态
-- ----------------------------------------------------------------------------
GameConfig.States = {
    MAIN_MENU   = "MAIN_MENU",
    PLAYING     = "PLAYING",
    DIALOGUE    = "DIALOGUE",
    CHARACTER_PANEL = "CHARACTER_PANEL",
    MAP         = "MAP",
    PAUSED      = "PAUSED",
    EDITOR      = "EDITOR",
    DEAD        = "DEAD",
    LEVEL_UP    = "LEVEL_UP",
    END_CREDITS = "END_CREDITS",
    SHOP            = "SHOP",
    EXCHANGE_SHOP   = "EXCHANGE_SHOP",
}

-- ----------------------------------------------------------------------------
-- 物品ID列表
-- ----------------------------------------------------------------------------
GameConfig.Items = {
    FIRE_DRAGON_CARD = "fire_dragon_card",     -- 火龙牌
    PEACE_JADE       = "peace_jade",           -- 平安玉
    SECRET_KEY       = "secret_key",           -- 密钥
    BAGUA_MIRROR     = "bagua_mirror",         -- 镇宅八卦镜
    EXORCISM_TALISMAN = "exorcism_talisman",   -- 驱邪符
    MYSTERY_FRAGMENT = "mystery_fragment",     -- 神秘碎片
    OPENED_SCROLL    = "opened_scroll",        -- 打开的密卷
    SEALED_SCROLL    = "sealed_scroll",        -- 被封印的密卷
    SECRET_BOX       = "secret_box",           -- 密盒
    HOLY_WATER       = "holy_water",           -- 圣水
}

-- ----------------------------------------------------------------------------
-- NPC ID列表
-- ----------------------------------------------------------------------------
GameConfig.NPCs = {
    AYANG      = "ayang",       -- 阿阳
    QIQI       = "qiqi",        -- 七七
    WENGMOLAO  = "wengmolao",   -- 嗡摩佬
    TUDI_SHEN  = "tudi_shen",   -- 山根土地神
    CUNZHANG   = "cunzhang",    -- 村长
}

-- NPC 功能标记：哪些 NPC 拥有商店/兑换商店
GameConfig.NPCFeatures = {
    ["cunzhang"]  = { shop = true },               -- 村长开商店
    ["wengmolao"] = { exchange = true },            -- 嗡摩佬开兑换商店
}

-- ----------------------------------------------------------------------------
-- 辅助函数：创建三渲二 PBR 材质
-- ----------------------------------------------------------------------------
---@param color Color 颜色
---@param roughness? number 粗糙度 (默认使用 DefaultRoughness)
---@param metallic? number 金属度 (默认使用 DefaultMetallic)
---@return Material
function GameConfig.CreateMaterial(color, roughness, metallic)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", GameConfig.Material.Technique))
    mat:SetShaderParameter("MatDiffColor", Variant(color))
    mat:SetShaderParameter("Roughness", Variant(roughness or GameConfig.Material.DefaultRoughness))
    mat:SetShaderParameter("Metallic", Variant(metallic or GameConfig.Material.DefaultMetallic))
    return mat
end

---@param color Color 颜色
---@param roughness? number 粗糙度
---@return Material
function GameConfig.CreateAlphaMaterial(color, roughness)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", GameConfig.Material.TechniqueAlpha))
    mat:SetShaderParameter("MatDiffColor", Variant(color))
    mat:SetShaderParameter("Roughness", Variant(roughness or GameConfig.Material.DefaultRoughness))
    mat:SetShaderParameter("Metallic", Variant(0.0))
    return mat
end

---@param color Color 发光颜色
---@param intensity? number 强度倍率 (默认1.0)
---@return Material
function GameConfig.CreateEmissiveMaterial(color, intensity)
    intensity = intensity or 1.0
    local mat = GameConfig.CreateMaterial(color)
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(
        color.r * intensity,
        color.g * intensity,
        color.b * intensity
    )))
    return mat
end

-- ----------------------------------------------------------------------------
-- 升级系统
-- ----------------------------------------------------------------------------
GameConfig.Leveling = {
    XPPerOrb      = 5,       -- 每个经验球的经验值
    OrbsNormal    = 5,       -- 普通怪掉落经验球数
    OrbsBoss      = 20,      -- Boss 掉落经验球数
    BaseXP        = 100,     -- 初始升级所需经验
    GrowthRate    = 1.15,    -- 每级经验递增倍率
    OrbSpeed      = 8.0,     -- 经验球飞向玩家的速度
    OrbCollectDist = 1.2,    -- 经验球吸收距离
    OrbMagnetDist  = 5.0,    -- 经验球开始被吸引距离
    OrbScatterDist = 2.0,    -- 经验球初始散开距离
    OrbScatterTime = 0.4,    -- 经验球散开时间

    -- 击杀拾取范围加成
    OrbRangeKillInterval = 20,   -- 每杀N个小怪触发一次加成
    OrbRangeBonusPct     = 0.01, -- 每次加成 +1% 拾取范围

    -- 血包掉落
    HealthDropChance = 0.10,  -- 小怪死亡掉落血包概率 10%
    HealthDropHeal  = 20,     -- 每个血包回复的生命值
    HealthDropLife  = 15.0,   -- 血包在地面存在秒数
    HealthCollectDist = 1.5,  -- 拾取距离
}

-- 属性加成选项（每级三选一）
GameConfig.Attributes = {
    {
        id = "attackSpeed", name = "攻速提升",
        icon = "⚡", desc = "攻击冷却 -8%",
        apply = function(bonuses) bonuses.attackSpeed = (bonuses.attackSpeed or 0) + 8 end,
    },
    {
        id = "maxHP", name = "生命强化",
        icon = "❤", desc = "最大生命 +20",
        apply = function(bonuses) bonuses.maxHP = (bonuses.maxHP or 0) + 20 end,
    },
    {
        id = "cooldown", name = "冷却缩减",
        icon = "🔄", desc = "技能冷却 -10%",
        apply = function(bonuses) bonuses.cooldown = (bonuses.cooldown or 0) + 10 end,
    },
    {
        id = "range", name = "范围扩展",
        icon = "🎯", desc = "攻击范围 +15%",
        apply = function(bonuses) bonuses.range = (bonuses.range or 0) + 15 end,
    },
    {
        id = "count", name = "多重打击",
        icon = "💥", desc = "攻击附带一次额外伤害(50%)",
        apply = function(bonuses) bonuses.count = (bonuses.count or 0) + 1 end,
    },
    {
        id = "attackSize", name = "攻击大小",
        icon = "🔶", desc = "攻击范围面积 +20%",
        apply = function(bonuses) bonuses.attackSize = (bonuses.attackSize or 0) + 20 end,
    },
    {
        id = "attackCount", name = "攻击次数",
        icon = "🔱", desc = "攻击额外发射一枚弹体",
        apply = function(bonuses) bonuses.attackCount = (bonuses.attackCount or 0) + 1 end,
    },
}

-- 十级技能选项（每10级三选一）
GameConfig.LevelSkills = {
    {
        id = "shockwave", name = "冲击波",
        icon = "🌊", type = "范围技能",
        desc = "对周围8米内所有敌人造成40点伤害",
        damage = 40, range = 8.0, cooldown = 15.0,
    },
    {
        id = "timeFreeze", name = "时间冻结",
        icon = "⏳", type = "控制技能",
        desc = "冻结周围10米所有敌人5秒",
        range = 10.0, duration = 5.0, cooldown = 20.0,
    },
    {
        id = "lightningStorm", name = "雷暴",
        icon = "⛈", type = "攻击技能",
        desc = "召唤闪电打击周围6米内敌人,每道60伤害",
        damage = 60, range = 6.0, strikes = 5, cooldown = 18.0,
    },
    {
        id = "fireStorm", name = "火焰风暴",
        icon = "🔥", type = "持续伤害",
        desc = "释放火焰旋风,持续灼烧周围7米敌人3秒",
        damage = 20, range = 7.0, duration = 3.0, ticks = 6, cooldown = 22.0,
    },
    {
        id = "voidPull", name = "暗影牵引",
        icon = "🌀", type = "控制技能",
        desc = "将周围10米敌人拉向自身并造成35伤害",
        damage = 35, range = 10.0, pullStrength = 6.0, cooldown = 16.0,
    },
    {
        id = "healAura", name = "治愈光环",
        icon = "💚", type = "辅助技能",
        desc = "恢复40%最大生命值并获得短暂护盾",
        healPercent = 0.4, shieldDuration = 3.0, cooldown = 25.0,
    },
}

-- ----------------------------------------------------------------------------
-- 区域Boss配置（每局开始刷新，固定位置，击杀掉落装备）
-- =========== 新增 6 个技能 ===========
GameConfig.ExtraSkills = {
    {
        id = "flameSlash", name = "烈焰斩",
        icon = "🗡", type = "攻击技能",
        desc = "向前方扇形区域释放烈焰斩击,造成高额伤害",
        damage = 80, range = 6.0, angle = 90, cooldown = 14.0,
    },
    {
        id = "iceArmor", name = "寒冰护甲",
        icon = "🛡", type = "防御技能",
        desc = "获得冰霜护甲,减伤50%并反弹伤害给近战攻击者",
        duration = 5.0, damageReduction = 0.5, reflectDamage = 15, cooldown = 24.0,
    },
    {
        id = "chainLightning", name = "连锁闪电",
        icon = "⚡", type = "攻击技能",
        desc = "释放可在敌人间弹跳的闪电,每次弹跳衰减20%",
        damage = 50, bounces = 5, bounceRange = 8.0, decayRate = 0.8, cooldown = 12.0,
    },
    {
        id = "earthquakeSlam", name = "大地震击",
        icon = "💥", type = "范围技能",
        desc = "重击地面,短暂延迟后在大范围内造成爆发伤害",
        damage = 70, range = 10.0, delay = 0.6, cooldown = 20.0,
    },
    {
        id = "shadowClone", name = "暗影分身",
        icon = "👤", type = "召唤技能",
        desc = "召唤暗影分身自动攻击附近敌人,持续8秒",
        cloneDamage = 12, cloneCount = 2, duration = 8.0, attackInterval = 1.0, cooldown = 28.0,
    },
    {
        id = "lifeDrain", name = "生命汲取",
        icon = "💜", type = "攻击技能",
        desc = "对周围敌人造成伤害并吸取其生命值恢复自身",
        damage = 30, range = 7.0, healRatio = 0.5, cooldown = 18.0,
    },
}

-- 合并到 LevelSkills（保持兼容）
for _, skill in ipairs(GameConfig.ExtraSkills) do
    table.insert(GameConfig.LevelSkills, skill)
end

-- ----------------------------------------------------------------------------
-- 区域Boss配置（每局开始刷新，固定位置，击杀掉落装备）
-- ----------------------------------------------------------------------------
GameConfig.AreaBosses = {
    verdant_guardian = {
        name = "翠木守卫", icon = "🌿",
        hp = 600, damage = 25, attackRange = 3.5, detectRange = 18.0,
        chaseSpeed = 2.8, attackCooldown = 2.0,
        spawnPos = { x = 210, z = 220 },
        dropEquip = "verdant_heartwood",
        bodyColor    = Color(0.25, 0.55, 0.20, 1.0),
        accentColor  = Color(0.40, 0.75, 0.30, 1.0),
        glowColor    = Color(0.30, 0.90, 0.20, 1.0),
    },
    stone_colossus = {
        name = "岩魂巨像", icon = "🪨",
        hp = 900, damage = 35, attackRange = 4.0, detectRange = 16.0,
        chaseSpeed = 2.0, attackCooldown = 2.5,
        spawnPos = { x = -210, z = 210 },
        dropEquip = "stonecore_sigil",
        bodyColor    = Color(0.45, 0.40, 0.35, 1.0),
        accentColor  = Color(0.60, 0.55, 0.50, 1.0),
        glowColor    = Color(0.90, 0.60, 0.20, 1.0),
    },
    phantom_warden = {
        name = "幽影典狱长", icon = "👻",
        hp = 500, damage = 20, attackRange = 3.0, detectRange = 20.0,
        chaseSpeed = 3.5, attackCooldown = 1.8,
        spawnPos = { x = -200, z = -205 },
        dropEquip = "phantom_shackle",
        bodyColor    = Color(0.15, 0.10, 0.25, 1.0),
        accentColor  = Color(0.30, 0.20, 0.50, 1.0),
        glowColor    = Color(0.50, 0.30, 0.90, 1.0),
    },
    scorched_wyrm = {
        name = "焦土蛟蛇", icon = "🐍",
        hp = 700, damage = 30, attackRange = 5.0, detectRange = 22.0,
        chaseSpeed = 3.0, attackCooldown = 2.2,
        spawnPos = { x = 200, z = -220 },
        dropEquip = "ember_fang",
        bodyColor    = Color(0.60, 0.20, 0.08, 1.0),
        accentColor  = Color(0.90, 0.45, 0.10, 1.0),
        glowColor    = Color(1.00, 0.50, 0.10, 1.0),
    },
    shrine_demon = {
        name = "庙堂魔", icon = "👹",
        hp = 800, damage = 32, attackRange = 3.5, detectRange = 20.0,
        chaseSpeed = 2.6, attackCooldown = 2.0,
        spawnPos = { x = 0, z = 38 },
        dropEquip = "demon_mask_shard",
        bodyColor    = Color(0.50, 0.05, 0.05, 1.0),
        accentColor  = Color(0.80, 0.10, 0.10, 1.0),
        glowColor    = Color(1.00, 0.20, 0.00, 1.0),
    },
}

GameConfig.AreaBossOrder = {
    "verdant_guardian", "stone_colossus", "phantom_warden",
    "scorched_wyrm", "shrine_demon",
}

-- ----------------------------------------------------------------------------
-- 装备配置（区域Boss掉落，最多装备2件）
-- ----------------------------------------------------------------------------
GameConfig.Equipment = {
    verdant_heartwood = {
        name = "翠心木", icon = "🌳",
        desc = "翠木守卫的心材，蕴含生命之力",
        passive = { maxHP = 30, cooldownPct = 5 },
        proc = { type = "lifeSteal", chance = 0.20, amount = 8 },
        overlayColor = Color(0.3, 0.9, 0.2, 1.0),
        overlayIntensity = 1.5,
    },
    stonecore_sigil = {
        name = "岩心符印", icon = "🔶",
        desc = "岩魂巨像的核心符文，附带碎裂冲击",
        passive = { damagePct = 12, maxHP = 15 },
        proc = { type = "shatter", chance = 0.15, damage = 20, range = 4.0 },
        overlayColor = Color(0.9, 0.6, 0.2, 1.0),
        overlayIntensity = 1.8,
    },
    phantom_shackle = {
        name = "幽影镣铐", icon = "⛓",
        desc = "幽影典狱长的枷锁碎片，附带减速诅咒",
        passive = { atkSpdPct = 8, moveSpdPct = 5 },
        proc = { type = "slow", chance = 0.18, slowPct = 40, duration = 2.0 },
        overlayColor = Color(0.5, 0.3, 0.9, 1.0),
        overlayIntensity = 1.5,
    },
    ember_fang = {
        name = "余烬之牙", icon = "🔥",
        desc = "焦土蛟蛇的毒牙，附带灼烧效果",
        passive = { damagePct = 8, atkSpdPct = 5 },
        proc = { type = "burn", chance = 0.22, dps = 5, duration = 3.0 },
        overlayColor = Color(1.0, 0.4, 0.1, 1.0),
        overlayIntensity = 2.0,
    },
    demon_mask_shard = {
        name = "鬼面碎片", icon = "🎭",
        desc = "庙堂魔的面具碎片，附带狂暴增伤",
        passive = { cooldownPct = 8, rangePct = 10 },
        proc = { type = "demonRage", chance = 0.12, damageMult = 1.3, duration = 4.0 },
        overlayColor = Color(1.0, 0.15, 0.0, 1.0),
        overlayIntensity = 2.5,
    },
}

GameConfig.EquipmentOrder = {
    "verdant_heartwood", "stonecore_sigil", "phantom_shackle",
    "ember_fang", "demon_mask_shard",
}

-- ----------------------------------------------------------------------------
-- 击退参数
-- ----------------------------------------------------------------------------
GameConfig.Knockback = {
    Duration        = 0.3,    -- 击退持续秒数
    DecayRate       = 6.0,    -- 指数衰减率
    BossResistance  = 0.7,    -- Boss 抗击退比例（70%减免）
    MinVelocity     = 0.5,    -- 速度低于此值时停止击退
}

-- ----------------------------------------------------------------------------
-- 加载开发者面板保存的配置覆盖
-- ----------------------------------------------------------------------------

local OVERRIDES_FILE = "config-overrides.json"

--- 从 config-overrides.json 加载并覆盖 GameConfig 中对应的值
--- 路径格式: "Player.MoveSpeed" → GameConfig.Player.MoveSpeed
---@return number 成功覆盖的条目数
function GameConfig.LoadOverrides()
    if not fileSystem:FileExists(OVERRIDES_FILE) then return 0 end

    local rf = File(OVERRIDES_FILE, FILE_READ)
    if not rf:IsOpen() then return 0 end
    local ok, data = pcall(cjson.decode, rf:ReadString())
    rf:Close()
    if not ok or type(data) ~= "table" then return 0 end

    local count = 0
    for pathKey, value in pairs(data) do
        -- 按 "." 分割路径
        local parts = {}
        for part in pathKey:gmatch("[^%.]+") do
            table.insert(parts, part)
        end

        -- 沿路径导航到目标表
        local tbl = GameConfig
        for i = 1, #parts - 1 do
            tbl = tbl[parts[i]]
            if type(tbl) ~= "table" then
                tbl = nil
                break
            end
        end

        -- 设置值
        if tbl and parts[#parts] then
            local key = parts[#parts]
            if tbl[key] ~= nil and type(tbl[key]) == "number" and type(value) == "number" then
                tbl[key] = value
                count = count + 1
            end
        end
    end

    if count > 0 then
        print("[GameConfig] 已加载 " .. count .. " 项配置覆盖")
    end
    return count
end

-- ----------------------------------------------------------------------------
-- 商店系统配置
-- ----------------------------------------------------------------------------
GameConfig.Shop = {
    Prices = {
        fire_dragon_card  = 100,   -- 火龙牌
        peace_jade        = 150,   -- 平安玉
        secret_key        = 120,   -- 密钥
        bagua_mirror      = 250,   -- 八卦镜
        exorcism_talisman = 180,   -- 驱邪符
        mystery_fragment  = 200,   -- 神秘碎片
        opened_scroll     = 300,   -- 残破书卷
        sealed_scroll     = 350,   -- 封印书卷
        secret_box        = 280,   -- 秘匣
        holy_water        = 400,   -- 圣水
        thunder_drum      = 350,   -- 雷鼓
        shadow_fan        = 450,   -- 影扇
        blood_compass     = 500,   -- 血罗盘
        jade_flute        = 550,   -- 玉笛
        spirit_bell       = 600,   -- 灵铃
    },

    -- 水晶价格（用于扩展词条槽 + 附带对应品质词条）
    CrystalPrices = {
        crystal_t1 = 100,    -- 初级水晶
        crystal_t2 = 300,    -- 中级水晶
        crystal_t3 = 800,    -- 高级水晶
        crystal_t4 = 2000,   -- 顶级水晶
        crystal_t5 = 5000,   -- 史诗水晶
        crystal_t6 = 15000,  -- 至臻水晶
    },

    -- NPC 词条刷新价格（按当前词条品质收费）
    RefreshPrices = {
        [1] = 50,    -- 普通词条
        [2] = 150,   -- 中级词条
        [3] = 400,   -- 高级词条
        [4] = 1000,  -- 顶级词条
        [5] = 3000,  -- 史诗词条
        [6] = 8000,  -- 至臻词条
    },
}

-- ----------------------------------------------------------------------------
-- 觉醒系统配置
-- ----------------------------------------------------------------------------
GameConfig.Awakening = {
    -- 觉醒等级阈值（累计觉醒点）：0→1→2→3→4→5
    LevelThresholds = { 500, 2000, 5000, 10000, 20000 },

    -- 分解基础觉醒点（按物品品级）
    DismantleBase = {
        [1] = 5,    -- 普通
        [2] = 15,   -- 优秀
        [3] = 40,   -- 稀有
        [4] = 100,  -- 史诗
        [5] = 250,  -- 传说
    },

    -- 词条额外觉醒点（按词条品质）
    DismantleAffixBonus = {
        [1] = 2,    -- 普通词条
        [2] = 5,    -- 中级
        [3] = 12,   -- 高级
        [4] = 30,   -- 顶级
        [5] = 80,   -- 史诗
        [6] = 200,  -- 至臻
    },

    LevelNames  = { "未觉醒", "觉醒", "二次觉醒", "三次觉醒", "四次觉醒", "五次觉醒" },
    LevelColors = { {150,150,150}, {100,200,255}, {255,180,50}, {255,80,80}, {200,50,255}, {255,215,0} },
    LevelIcons  = { "", "✦", "✦✦", "✦✦✦", "✦✦✦✦", "✦✦✦✦✦" },
}

-- ----------------------------------------------------------------------------
-- 兑换商店配置
-- ----------------------------------------------------------------------------
GameConfig.ExchangeShop = {
    -- 货币兑换汇率
    GoldPerCrystal  = 10,   -- 10 金币 → 1 水晶
    CrystalPerGold  = 8,    -- 1 水晶 → 8 金币
    -- 兑换预设额度
    GoldPresets    = { 100, 500, 1000 },    -- 金币→水晶 预设
    CrystalPresets = { 10, 50, 100 },       -- 水晶→金币 预设

    -- 稀有武器兑换（水晶购买指定品级随机武器）
    RareWeaponCosts = {
        [3] = 50,    -- 稀有品质
        [4] = 150,   -- 史诗品质
        [5] = 500,   -- 传说品质
    },

    -- 装备兑换（水晶购买 Boss 装备）
    EquipmentCosts = {
        verdant_heartwood = { crystal = 80,  rarity = 3 },
        stonecore_sigil   = { crystal = 100, rarity = 3 },
        phantom_shackle   = { crystal = 90,  rarity = 3 },
        ember_fang        = { crystal = 110, rarity = 4 },
        demon_mask_shard  = { crystal = 150, rarity = 4 },
    },
}

-- ----------------------------------------------------------------------------
-- 手柄配置
-- ----------------------------------------------------------------------------
GameConfig.Gamepad = {
    Sensitivity = 1.5,      -- 右摇杆视角灵敏度倍率
    Deadzone    = 0.15,     -- 摇杆死区阈值
}

-- ----------------------------------------------------------------------------
-- 安全区配置
-- ----------------------------------------------------------------------------
GameConfig.SafeZone = {
    CenterX         = 0,         -- 安全区中心 X
    CenterZ         = 0,         -- 安全区中心 Z
    Radius          = 40.0,      -- 安全区半径 m
    PushBackOffset  = 1.0,       -- 推回偏移距离 m（边界内侧）
    WireframeY      = 0.3,       -- 线框绘制高度 Y
    WireframeSegments = 64,      -- 线框圆圈分段数
}

return GameConfig
