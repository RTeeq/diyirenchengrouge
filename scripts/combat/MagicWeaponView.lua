-- ============================================================================
-- MagicWeaponView.lua — 第一人称魔法/远程武器 + 徒手视图
-- 每种武器/徒手都有独特手持模型 + idle微晃 + 施法动画
-- ============================================================================

local GameConfig = require("config.GameConfig")

local MagicWeaponView = {}

-- ============================================================================
-- 动画状态
-- ============================================================================
local STATE_IDLE = "IDLE"
local STATE_CAST = "CAST"

local CAST_DURATION = 0.30  -- 施法动画总时长

-- 武器静止位姿（相对于 cameraNode_）— 左手侧
local REST_POS = Vector3(-0.35, -0.35, 0.48)
local REST_ROT = Quaternion(-5, -10, 3)

-- 施法关键帧（左手侧）
local CAST_RAISE_POS = Vector3(-0.28, -0.15, 0.55)
local CAST_RAISE_ROT = Quaternion(-25, -5, 8)
local CAST_PUSH_POS  = Vector3(-0.22, -0.22, 0.62)
local CAST_PUSH_ROT  = Quaternion(5, 0, -5)

-- ============================================================================
-- 模块状态
-- ============================================================================

---@type Node
local weaponPivot_ = nil
---@type Node
local cameraNode_ = nil
---@type Scene
local scene_ = nil

local animState_ = STATE_IDLE
local stateTimer_ = 0.0
local time_ = 0.0

local currentPos_ = Vector3(0, 0, 0)
local currentRot_ = Quaternion()

local currentWeaponId_ = nil  -- nil = barehand
local activeModelId_ = nil    -- 当前已构建的模型ID

-- ============================================================================
-- 缓动函数
-- ============================================================================

local function easeOutQuad(t)
    return 1.0 - (1.0 - t) * (1.0 - t)
end

local function easeOutBack(t)
    local c = 1.4
    return 1.0 + c * math.pow(t - 1, 3) + (c - 1) * math.pow(t - 1, 2)
end

local function lerpVec3(a, b, t)
    return Vector3(
        a.x + (b.x - a.x) * t,
        a.y + (b.y - a.y) * t,
        a.z + (b.z - a.z) * t
    )
end

-- ============================================================================
-- 材质工具（与 MeleeWeaponView 一致）
-- ============================================================================

local function makeMat(color, roughness, metallic)
    return GameConfig.CreateMaterial(color, roughness or 0.92, metallic or 0.0)
end

local function makeGlow(color, intensity)
    return GameConfig.CreateEmissiveMaterial(color, intensity or 2.0)
end

local function makeAlpha(color, roughness)
    return GameConfig.CreateAlphaMaterial(color, roughness)
end

-- ============================================================================
-- 辅助：创建模型部件
-- ============================================================================

local function createPart(parent, name, modelName, scaleVec, posVec, material, rot)
    local node = parent:CreateChild(name)
    node.position = posVec
    node:SetScale(scaleVec)
    if rot then node.rotation = rot end
    local mdl = node:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/" .. modelName .. ".mdl"))
    mdl:SetMaterial(material)
    return node
end

local function addGlowLight(parent, pos, color, range, brightness)
    local n = parent:CreateChild("GlowLight")
    n.position = pos
    local pl = n:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = range or 1.5
    pl.color = color
    pl.brightness = brightness or 1.2
    return n
end

-- ============================================================================
-- 武器模型构建函数（每个返回 pivot 子节点）
-- ============================================================================

--- 徒手拳头
local function buildBareHands(pivot)
    local skinColor = Color(0.85, 0.70, 0.55, 1.0)
    local skinMat = makeMat(skinColor, 0.95)
    local knuckleMat = makeMat(Color(0.75, 0.60, 0.48, 1.0), 0.95)

    -- 手掌（扁平方块）
    createPart(pivot, "Palm", "Box",
        Vector3(0.12, 0.08, 0.14), Vector3(0, 0, 0), skinMat)

    -- 四根手指（握拳状态）
    for i = 1, 4 do
        local xOff = -0.04 + (i - 1) * 0.025
        -- 指节
        createPart(pivot, "Finger" .. i, "Box",
            Vector3(0.022, 0.025, 0.06), Vector3(xOff, 0.04, 0.06), knuckleMat,
            Quaternion(30, Vector3.RIGHT))
        -- 指尖（弯曲部分）
        createPart(pivot, "FingerTip" .. i, "Box",
            Vector3(0.020, 0.022, 0.04), Vector3(xOff, 0.02, 0.02), knuckleMat,
            Quaternion(60, Vector3.RIGHT))
    end

    -- 拇指
    createPart(pivot, "Thumb", "Box",
        Vector3(0.025, 0.025, 0.05), Vector3(0.065, 0.01, 0.03), skinMat,
        Quaternion(-20, Vector3.FORWARD) * Quaternion(30, Vector3.RIGHT))
end

--- 火龙牌 — 手持红色符牌
local function buildFireDragonCard(pivot)
    local cfg = GameConfig.Weapons.fire_dragon_card

    -- 卡片主体
    createPart(pivot, "Card", "Box",
        Vector3(0.20, 0.28, 0.02), Vector3(0, 0.12, 0),
        makeGlow(cfg.color, 1.5))

    -- 边框
    local darkRed = makeMat(Color(0.5, 0.12, 0.08, 1.0))
    createPart(pivot, "BorderTop", "Box",
        Vector3(0.22, 0.015, 0.025), Vector3(0, 0.27, 0), darkRed)
    createPart(pivot, "BorderBot", "Box",
        Vector3(0.22, 0.015, 0.025), Vector3(0, -0.03, 0), darkRed)
    createPart(pivot, "BorderL", "Box",
        Vector3(0.015, 0.30, 0.025), Vector3(-0.105, 0.12, 0), darkRed)
    createPart(pivot, "BorderR", "Box",
        Vector3(0.015, 0.30, 0.025), Vector3(0.105, 0.12, 0), darkRed)

    -- 龙纹浮雕
    createPart(pivot, "Emblem", "Pyramid",
        Vector3(0.07, 0.06, 0.07), Vector3(0, 0.15, 0.015),
        makeGlow(Color(1.0, 0.6, 0.1, 1.0), 2.5))

    addGlowLight(pivot, Vector3(0, 0.15, 0.08), Color(1.0, 0.4, 0.1), 2.0, 1.5)
end

--- 平安玉 — 手持翡翠圆玉
local function buildPeaceJade(pivot)
    local cfg = GameConfig.Weapons.peace_jade
    local jadeMat = makeGlow(cfg.color, 1.2)

    -- 玉盘主体
    createPart(pivot, "JadeDisc", "Cylinder",
        Vector3(0.14, 0.025, 0.14), Vector3(0, 0.10, 0), jadeMat)

    -- 中心孔（深色环）
    createPart(pivot, "CenterHole", "Torus",
        Vector3(0.04, 0.04, 0.04), Vector3(0, 0.10, 0),
        makeMat(Color(0.15, 0.5, 0.25, 1.0)))

    -- 玉珠装饰（底部悬挂）
    createPart(pivot, "Bead1", "Sphere",
        Vector3(0.02, 0.02, 0.02), Vector3(-0.03, -0.02, 0),
        makeGlow(Color(0.4, 0.95, 0.6, 1.0), 2.0))
    createPart(pivot, "Bead2", "Sphere",
        Vector3(0.015, 0.015, 0.015), Vector3(0.03, -0.04, 0),
        makeGlow(Color(0.4, 0.95, 0.6, 1.0), 2.0))

    -- 流苏绳
    createPart(pivot, "Cord", "Cylinder",
        Vector3(0.005, 0.06, 0.005), Vector3(0, -0.01, 0),
        makeMat(Color(0.8, 0.2, 0.15, 1.0)))

    addGlowLight(pivot, Vector3(0, 0.10, 0.06), cfg.color, 2.0, 1.0)
end

--- 密钥 — 手持金色钥匙
local function buildSecretKey(pivot)
    local cfg = GameConfig.Weapons.secret_key
    local goldMat = makeGlow(cfg.color, 1.2)
    local darkGold = makeMat(Color(0.5, 0.4, 0.12, 1.0))

    -- 钥匙柄
    createPart(pivot, "Shaft", "Cylinder",
        Vector3(0.025, 0.22, 0.025), Vector3(0, 0.05, 0), goldMat)

    -- 钥匙环
    createPart(pivot, "Ring", "Torus",
        Vector3(0.06, 0.06, 0.06), Vector3(0, 0.20, 0), goldMat)

    -- 钥匙齿
    for i = 1, 3 do
        createPart(pivot, "Tooth" .. i, "Box",
            Vector3(0.03, 0.025 + i * 0.008, 0.015),
            Vector3(0.025, -0.08 - (i - 1) * 0.025, 0), darkGold)
    end

    -- 宝石
    createPart(pivot, "Gem", "Sphere",
        Vector3(0.02, 0.02, 0.02), Vector3(0, 0.20, 0),
        makeGlow(Color(0.2, 0.8, 0.3, 1.0), 3.0))

    addGlowLight(pivot, Vector3(0, 0.20, 0.04), Color(0.9, 0.8, 0.3), 1.5, 1.2)
end

--- 八卦镜 — 手持镜盘
local function buildBaguaMirror(pivot)
    local cfg = GameConfig.Weapons.bagua_mirror
    local mirrorMat = makeGlow(cfg.color, 1.5)

    -- 镜面主体
    createPart(pivot, "MirrorDisc", "Cylinder",
        Vector3(0.14, 0.015, 0.14), Vector3(0, 0.10, 0), mirrorMat)

    -- 镜面反光层
    createPart(pivot, "MirrorSurface", "Cylinder",
        Vector3(0.11, 0.008, 0.11), Vector3(0, 0.105, 0.001),
        makeMat(Color(0.9, 0.9, 0.95, 1.0), 0.1, 0.9))

    -- 镜框（外圈）
    createPart(pivot, "Frame", "Torus",
        Vector3(0.10, 0.10, 0.10), Vector3(0, 0.10, 0),
        makeMat(Color(0.55, 0.35, 0.18, 1.0)))

    -- 八卦符号（中心菱形）
    createPart(pivot, "BaguaSymbol", "Pyramid",
        Vector3(0.04, 0.03, 0.04), Vector3(0, 0.115, 0),
        makeGlow(Color(1.0, 0.9, 0.5, 1.0), 2.0))

    -- 握柄
    createPart(pivot, "Handle", "Cylinder",
        Vector3(0.025, 0.10, 0.025), Vector3(0, -0.04, 0),
        makeMat(Color(0.45, 0.30, 0.15, 1.0)))

    addGlowLight(pivot, Vector3(0, 0.12, 0.06), cfg.color, 2.5, 1.8)
end

--- 驱邪符 — 手持黄色符纸
local function buildExorcismTalisman(pivot)
    local cfg = GameConfig.Weapons.exorcism_talisman

    -- 符纸主体
    createPart(pivot, "Paper", "Box",
        Vector3(0.14, 0.22, 0.012), Vector3(0, 0.08, 0),
        makeGlow(cfg.color, 1.2))

    -- 朱砂竖线
    createPart(pivot, "RuneV", "Box",
        Vector3(0.012, 0.14, 0.004), Vector3(0, 0.08, 0.008),
        makeMat(Color(0.8, 0.1, 0.05, 1.0)))

    -- 朱砂横线
    createPart(pivot, "RuneH", "Box",
        Vector3(0.08, 0.012, 0.004), Vector3(0, 0.12, 0.008),
        makeMat(Color(0.8, 0.1, 0.05, 1.0)))

    -- 圆印
    createPart(pivot, "Stamp", "Cylinder",
        Vector3(0.03, 0.004, 0.03), Vector3(0, 0.01, 0.008),
        makeMat(Color(0.8, 0.1, 0.05, 1.0)))

    -- 流苏
    for i, side in ipairs({-1, 1}) do
        createPart(pivot, "Tassel" .. i, "Cylinder",
            Vector3(0.006, 0.06, 0.006), Vector3(side * 0.03, -0.08, 0),
            makeMat(Color(0.8, 0.1, 0.05, 1.0)))
    end

    addGlowLight(pivot, Vector3(0, 0.10, 0.05), Color(0.9, 0.8, 0.2), 1.8, 1.0)
end

--- 神秘碎片 — 手持水晶碎片
local function buildMysteryFragment(pivot)
    local cfg = GameConfig.Weapons.mystery_fragment

    -- 主晶体
    createPart(pivot, "Crystal", "Pyramid",
        Vector3(0.10, 0.20, 0.10), Vector3(0, 0.08, 0),
        makeGlow(cfg.color, 2.0))

    -- 倒置底座
    createPart(pivot, "Base", "Pyramid",
        Vector3(0.07, 0.08, 0.07), Vector3(0, -0.02, 0),
        makeGlow(cfg.color, 1.5), Quaternion(180, Vector3.RIGHT))

    -- 内核发光球
    createPart(pivot, "Core", "Sphere",
        Vector3(0.04, 0.04, 0.04), Vector3(0, 0.08, 0),
        makeGlow(Color(0.7, 0.9, 1.0, 1.0), 4.0))

    -- 环绕碎片
    for i = 1, 3 do
        local ang = math.rad((i - 1) * 120)
        createPart(pivot, "Shard" .. i, "Pyramid",
            Vector3(0.025, 0.04, 0.025),
            Vector3(math.sin(ang) * 0.09, 0.08, math.cos(ang) * 0.09),
            makeGlow(cfg.color, 1.0),
            Quaternion(i * 30, Vector3.UP))
    end

    addGlowLight(pivot, Vector3(0, 0.10, 0.04), cfg.color, 3.0, 2.0)
end

--- 打开的密卷 — 手持展开卷轴
local function buildOpenedScroll(pivot)
    local cfg = GameConfig.Weapons.opened_scroll
    local scrollMat = makeMat(Color(0.90, 0.85, 0.70, 1.0))
    local woodMat = makeMat(Color(0.4, 0.25, 0.12, 1.0))

    -- 卷轴纸面（展开状态）
    createPart(pivot, "Paper", "Box",
        Vector3(0.22, 0.16, 0.008), Vector3(0, 0.10, 0), scrollMat)

    -- 左右卷轴杆
    for i, side in ipairs({-1, 1}) do
        createPart(pivot, "Rod" .. i, "Cylinder",
            Vector3(0.015, 0.18, 0.015), Vector3(side * 0.115, 0.10, 0), woodMat)
        -- 杆端帽
        createPart(pivot, "Cap" .. i, "Sphere",
            Vector3(0.02, 0.02, 0.02), Vector3(side * 0.115, 0.20, 0), woodMat)
    end

    -- 文字纹路（几条横线）
    local inkMat = makeMat(Color(0.2, 0.2, 0.2, 1.0))
    for i = 1, 3 do
        createPart(pivot, "Text" .. i, "Box",
            Vector3(0.14, 0.005, 0.003),
            Vector3(0, 0.06 + i * 0.03, 0.005), inkMat)
    end

    -- 旋风辉光
    addGlowLight(pivot, Vector3(0, 0.12, 0.05), cfg.color, 1.5, 1.0)
end

--- 被封印的密卷 — 手持封印卷轴
local function buildSealedScroll(pivot)
    local cfg = GameConfig.Weapons.sealed_scroll
    local scrollMat = makeGlow(Color(0.90, 0.82, 0.65, 1.0), 0.8)
    local woodMat = makeMat(Color(0.4, 0.25, 0.12, 1.0))

    -- 卷轴主体（卷起状态）
    createPart(pivot, "Body", "Cylinder",
        Vector3(0.045, 0.22, 0.045), Vector3(0, 0.05, 0), scrollMat)

    -- 两端木帽
    for i, side in ipairs({-1, 1}) do
        createPart(pivot, "Cap" .. i, "Cylinder",
            Vector3(0.06, 0.015, 0.06), Vector3(0, 0.05 + side * 0.12, 0), woodMat)
    end

    -- 绑绳（环绕）
    createPart(pivot, "Rope", "Torus",
        Vector3(0.038, 0.038, 0.038), Vector3(0, 0.05, 0),
        makeMat(Color(0.35, 0.2, 0.1, 1.0)))

    -- 封蜡
    createPart(pivot, "Seal", "Cylinder",
        Vector3(0.025, 0.006, 0.025), Vector3(0, 0.05, 0.048),
        makeMat(Color(0.7, 0.12, 0.08, 1.0)))

    -- 冰蓝辉光
    addGlowLight(pivot, Vector3(0, 0.08, 0.05), cfg.color, 1.8, 1.2)
end

--- 密盒 — 手持木质密盒
local function buildSecretBox(pivot)
    local cfg = GameConfig.Weapons.secret_box
    local woodMat = makeMat(cfg.color)
    local darkWood = makeMat(Color(0.35, 0.22, 0.12, 1.0))
    local metalMat = makeMat(Color(0.5, 0.45, 0.3, 1.0))

    -- 盒体
    createPart(pivot, "Body", "Box",
        Vector3(0.18, 0.10, 0.13), Vector3(0, 0.06, 0), woodMat)

    -- 盒盖
    createPart(pivot, "Lid", "Box",
        Vector3(0.19, 0.02, 0.14), Vector3(0, 0.12, 0), darkWood)

    -- 锁扣
    createPart(pivot, "Lock", "Box",
        Vector3(0.03, 0.03, 0.015), Vector3(0, 0.08, 0.07), metalMat)

    -- 角件
    local corners = {
        Vector3(-0.09, 0.01, 0.065), Vector3(0.09, 0.01, 0.065),
        Vector3(-0.09, 0.01, -0.065), Vector3(0.09, 0.01, -0.065),
    }
    for i, pos in ipairs(corners) do
        createPart(pivot, "Corner" .. i, "Box",
            Vector3(0.02, 0.02, 0.02), pos, metalMat)
    end

    addGlowLight(pivot, Vector3(0, 0.08, 0.06), cfg.color, 1.5, 0.8)
end

--- 圣水 — 手持圣水瓶
local function buildHolyWater(pivot)
    local cfg = GameConfig.Weapons.holy_water
    local glassMat = makeAlpha(Color(0.85, 0.88, 1.0, 0.5))
    local waterMat = makeGlow(Color(0.7, 0.8, 1.0, 1.0), 1.5)
    local corkMat = makeMat(Color(0.6, 0.45, 0.25, 1.0))

    -- 瓶身
    createPart(pivot, "Bottle", "Cylinder",
        Vector3(0.05, 0.16, 0.05), Vector3(0, 0.04, 0), glassMat)

    -- 瓶内液体
    createPart(pivot, "Water", "Cylinder",
        Vector3(0.04, 0.10, 0.04), Vector3(0, 0.01, 0), waterMat)

    -- 瓶颈
    createPart(pivot, "Neck", "Cylinder",
        Vector3(0.025, 0.04, 0.025), Vector3(0, 0.14, 0), glassMat)

    -- 软木塞
    createPart(pivot, "Cork", "Cylinder",
        Vector3(0.028, 0.025, 0.028), Vector3(0, 0.17, 0), corkMat)

    -- 瓶底宝石
    createPart(pivot, "BottomGem", "Sphere",
        Vector3(0.015, 0.015, 0.015), Vector3(0, -0.05, 0),
        makeGlow(Color(0.9, 0.9, 1.0, 1.0), 3.0))

    -- 十字标记
    createPart(pivot, "CrossV", "Box",
        Vector3(0.008, 0.06, 0.003), Vector3(0, 0.05, 0.028),
        makeGlow(Color(1.0, 1.0, 0.8, 1.0), 2.0))
    createPart(pivot, "CrossH", "Box",
        Vector3(0.035, 0.008, 0.003), Vector3(0, 0.06, 0.028),
        makeGlow(Color(1.0, 1.0, 0.8, 1.0), 2.0))

    addGlowLight(pivot, Vector3(0, 0.08, 0.05), Color(0.9, 0.9, 1.0), 2.0, 1.5)
end

--- 雷鼓 — 手持铜鼓，蓝色雷纹
local function buildThunderDrum(pivot)
    local cfg = GameConfig.Weapons.thunder_drum
    local bodyMat = makeMat(Color(0.55, 0.40, 0.20, 1.0), 0.6, 0.4)
    local drumMat = makeMat(Color(0.8, 0.7, 0.5, 1.0), 0.8)

    -- 鼓身（扁圆柱）
    createPart(pivot, "DrumBody", "Cylinder",
        Vector3(0.13, 0.08, 0.13), Vector3(0, 0.06, 0), bodyMat)

    -- 鼓面（上）
    createPart(pivot, "DrumFace", "Cylinder",
        Vector3(0.12, 0.008, 0.12), Vector3(0, 0.105, 0), drumMat)

    -- 雷纹装饰（鼓面上的交叉线）
    local runeMat = makeGlow(cfg.glowColor, 3.0)
    createPart(pivot, "RuneH", "Box",
        Vector3(0.10, 0.004, 0.012), Vector3(0, 0.11, 0), runeMat)
    createPart(pivot, "RuneV", "Box",
        Vector3(0.012, 0.004, 0.10), Vector3(0, 0.11, 0), runeMat)

    -- 铜钉装饰（鼓沿四颗）
    for i = 1, 4 do
        local a = math.rad((i - 1) * 90)
        createPart(pivot, "Stud" .. i, "Sphere",
            Vector3(0.015, 0.015, 0.015),
            Vector3(math.cos(a) * 0.11, 0.105, math.sin(a) * 0.11),
            makeGlow(Color(0.8, 0.65, 0.2, 1.0), 1.5))
    end

    -- 鼓槌（右侧斜插）
    createPart(pivot, "Stick", "Cylinder",
        Vector3(0.012, 0.18, 0.012), Vector3(0.08, 0.08, 0.04),
        makeMat(Color(0.4, 0.25, 0.12, 1.0)),
        Quaternion(25, Vector3.FORWARD))
    -- 槌头
    createPart(pivot, "StickHead", "Sphere",
        Vector3(0.025, 0.025, 0.025), Vector3(0.04, 0.18, 0.02),
        makeMat(Color(0.9, 0.85, 0.7, 1.0)))

    addGlowLight(pivot, Vector3(0, 0.12, 0.06), cfg.glowColor, 2.5, 1.8)
end

--- 影扇 — 手持暗紫折扇
local function buildShadowFan(pivot)
    local cfg = GameConfig.Weapons.shadow_fan
    local fanMat = makeAlpha(Color(cfg.color.r, cfg.color.g, cfg.color.b, 0.7))
    local ribMat = makeMat(Color(0.15, 0.08, 0.22, 1.0), 0.7, 0.3)

    -- 展开的扇面（用多个薄片模拟）
    for i = 1, 7 do
        local ang = -45 + (i - 1) * 15
        local node = createPart(pivot, "Fan" .. i, "Box",
            Vector3(0.11, 0.15, 0.003),
            Vector3(0, 0.10, 0),
            fanMat,
            Quaternion(ang, Vector3.FORWARD))
        -- 扇骨
        createPart(node, "Rib", "Cylinder",
            Vector3(0.005, 0.16, 0.005), Vector3(0, 0, -0.003), ribMat)
    end

    -- 扇柄
    createPart(pivot, "Handle", "Cylinder",
        Vector3(0.018, 0.08, 0.018), Vector3(0, -0.04, 0),
        makeMat(Color(0.10, 0.05, 0.15, 1.0), 0.5, 0.2))

    -- 暗影辉光
    createPart(pivot, "GlowCore", "Sphere",
        Vector3(0.03, 0.03, 0.03), Vector3(0, 0.10, 0),
        makeGlow(cfg.glowColor, 3.0))

    addGlowLight(pivot, Vector3(0, 0.10, 0.05), cfg.glowColor, 2.0, 1.5)
end

--- 血罗盘 — 手持暗红色罗盘
local function buildBloodCompass(pivot)
    local cfg = GameConfig.Weapons.blood_compass
    local baseMat = makeMat(Color(0.25, 0.05, 0.05, 1.0), 0.7, 0.3)
    local needleMat = makeGlow(cfg.glowColor, 2.5)

    -- 罗盘盘面
    createPart(pivot, "Disc", "Cylinder",
        Vector3(0.13, 0.015, 0.13), Vector3(0, 0.08, 0), baseMat)

    -- 外圈刻度环
    createPart(pivot, "Ring", "Torus",
        Vector3(0.09, 0.09, 0.09), Vector3(0, 0.08, 0),
        makeMat(Color(0.5, 0.1, 0.05, 1.0), 0.5, 0.5))

    -- 罗盘指针（十字交叉）
    createPart(pivot, "NeedleN", "Box",
        Vector3(0.008, 0.005, 0.10), Vector3(0, 0.09, 0), needleMat)
    createPart(pivot, "NeedleE", "Box",
        Vector3(0.10, 0.005, 0.008), Vector3(0, 0.09, 0), needleMat)

    -- 中心血珠
    createPart(pivot, "BloodGem", "Sphere",
        Vector3(0.025, 0.025, 0.025), Vector3(0, 0.095, 0),
        makeGlow(Color(1.0, 0.1, 0.05, 1.0), 4.0))

    -- 符文点（四方位）
    for i = 1, 4 do
        local a = math.rad((i - 1) * 90 + 45)
        createPart(pivot, "Rune" .. i, "Sphere",
            Vector3(0.012, 0.012, 0.012),
            Vector3(math.cos(a) * 0.10, 0.09, math.sin(a) * 0.10),
            makeGlow(cfg.glowColor, 2.0))
    end

    addGlowLight(pivot, Vector3(0, 0.10, 0.06), cfg.glowColor, 2.5, 2.0)
end

--- 翠笛 — 手持翠绿竹笛
local function buildJadeFlute(pivot)
    local cfg = GameConfig.Weapons.jade_flute
    local jadeMat = makeGlow(cfg.color, 1.2)
    local holeMat = makeMat(Color(0.1, 0.3, 0.15, 1.0))

    -- 笛身（长圆柱，横置）
    createPart(pivot, "Body", "Cylinder",
        Vector3(0.02, 0.30, 0.02), Vector3(0, 0.05, 0), jadeMat,
        Quaternion(90, Vector3.FORWARD))

    -- 音孔（6个）
    for i = 1, 6 do
        createPart(pivot, "Hole" .. i, "Cylinder",
            Vector3(0.008, 0.005, 0.008),
            Vector3(-0.12 + (i - 1) * 0.04, 0.07, 0), holeMat)
    end

    -- 吹口
    createPart(pivot, "Mouth", "Box",
        Vector3(0.018, 0.008, 0.012), Vector3(0.16, 0.05, 0),
        makeMat(Color(0.2, 0.6, 0.3, 1.0)))

    -- 穗子装饰
    createPart(pivot, "Tassel", "Cylinder",
        Vector3(0.006, 0.06, 0.006), Vector3(-0.15, 0.0, 0),
        makeMat(Color(0.8, 0.2, 0.1, 1.0)))
    createPart(pivot, "TasselEnd", "Sphere",
        Vector3(0.012, 0.012, 0.012), Vector3(-0.15, -0.03, 0),
        makeMat(Color(0.8, 0.2, 0.1, 1.0)))

    addGlowLight(pivot, Vector3(0, 0.06, 0.04), cfg.glowColor, 2.0, 1.2)
end

--- 灵铃 — 手持蓝白铃铛
local function buildSpiritBell(pivot)
    local cfg = GameConfig.Weapons.spirit_bell
    local bellMat = makeGlow(cfg.color, 1.5)
    local handleMat = makeMat(Color(0.6, 0.5, 0.3, 1.0), 0.5, 0.4)

    -- 铃身（倒置半球 = Sphere + 底部圆柱遮挡）
    createPart(pivot, "BellBody", "Sphere",
        Vector3(0.10, 0.10, 0.10), Vector3(0, 0.02, 0), bellMat)

    -- 铃口（底部环）
    createPart(pivot, "BellRim", "Torus",
        Vector3(0.07, 0.07, 0.07), Vector3(0, -0.03, 0),
        makeMat(Color(0.5, 0.65, 0.8, 1.0), 0.4, 0.5))

    -- 铃舌
    createPart(pivot, "Clapper", "Sphere",
        Vector3(0.02, 0.02, 0.02), Vector3(0, -0.02, 0),
        makeGlow(Color(0.9, 0.95, 1.0, 1.0), 3.0))

    -- 握柄
    createPart(pivot, "Handle", "Cylinder",
        Vector3(0.015, 0.10, 0.015), Vector3(0, 0.10, 0), handleMat)

    -- 柄顶环
    createPart(pivot, "TopRing", "Torus",
        Vector3(0.025, 0.025, 0.025), Vector3(0, 0.16, 0), handleMat)

    -- 环绕小灵球装饰
    for i = 1, 3 do
        local a = math.rad((i - 1) * 120)
        createPart(pivot, "Orb" .. i, "Sphere",
            Vector3(0.015, 0.015, 0.015),
            Vector3(math.cos(a) * 0.08, 0.0, math.sin(a) * 0.08),
            makeGlow(cfg.glowColor, 2.5))
    end

    addGlowLight(pivot, Vector3(0, 0.02, 0.06), cfg.glowColor, 2.5, 1.5)
end

-- ============================================================================
-- 武器ID → 构建器映射
-- ============================================================================

local WEAPON_BUILDERS = {
    ["BareHands"]          = buildBareHands,
    ["fire_dragon_card"]   = buildFireDragonCard,
    ["peace_jade"]         = buildPeaceJade,
    ["secret_key"]         = buildSecretKey,
    ["bagua_mirror"]       = buildBaguaMirror,
    ["exorcism_talisman"]  = buildExorcismTalisman,
    ["mystery_fragment"]   = buildMysteryFragment,
    ["opened_scroll"]      = buildOpenedScroll,
    ["sealed_scroll"]      = buildSealedScroll,
    ["secret_box"]         = buildSecretBox,
    ["holy_water"]         = buildHolyWater,
    ["thunder_drum"]       = buildThunderDrum,
    ["shadow_fan"]         = buildShadowFan,
    ["blood_compass"]      = buildBloodCompass,
    ["jade_flute"]         = buildJadeFlute,
    ["spirit_bell"]        = buildSpiritBell,
}

-- ============================================================================
-- 模型管理
-- ============================================================================

local function destroyCurrentModel()
    if weaponPivot_ then
        weaponPivot_:Remove()
        weaponPivot_ = nil
    end
    activeModelId_ = nil
end

local function buildWeaponModel(weaponId)
    if not cameraNode_ then return end

    -- 如果已构建相同模型，直接返回
    if activeModelId_ == weaponId and weaponPivot_ then return end

    destroyCurrentModel()

    local builderId = weaponId or "iron_sword"
    local builder = WEAPON_BUILDERS[builderId]
    if not builder then
        -- 没有专用构建器的武器，用通用发光球
        builder = function(pivot)
            local cfg = GameConfig.Weapons[builderId]
            local col = (cfg and cfg.color) or Color(0.5, 0.5, 0.5, 1.0)
            createPart(pivot, "Orb", "Sphere",
                Vector3(0.08, 0.08, 0.08), Vector3(0, 0.08, 0),
                makeGlow(col, 2.0))
            addGlowLight(pivot, Vector3(0, 0.08, 0.04), col, 2.0, 1.5)
        end
    end

    weaponPivot_ = cameraNode_:CreateChild("MagicWeaponPivot")
    weaponPivot_.position = REST_POS
    weaponPivot_.rotation = REST_ROT

    builder(weaponPivot_)
    activeModelId_ = weaponId

    -- 初始位姿
    currentPos_ = Vector3(REST_POS.x, REST_POS.y, REST_POS.z)
    currentRot_ = Quaternion(REST_ROT.w, REST_ROT.x, REST_ROT.y, REST_ROT.z)
end

-- ============================================================================
-- 动画位姿计算
-- ============================================================================

local function getIdlePose(t)
    local bobY = math.sin(t * 2.0) * 0.006
    local bobX = math.sin(t * 1.3) * 0.003
    local rockZ = math.sin(t * 1.7) * 0.8
    local pos = Vector3(REST_POS.x + bobX, REST_POS.y + bobY, REST_POS.z)
    local rot = REST_ROT * Quaternion(0, 0, rockZ)
    return pos, rot
end

local function getCastPose(t)
    if t < 0.35 then
        -- 抬手蓄力
        local lt = easeOutQuad(t / 0.35)
        return lerpVec3(REST_POS, CAST_RAISE_POS, lt),
               REST_ROT:Slerp(CAST_RAISE_ROT, lt)
    elseif t < 0.60 then
        -- 前推释放
        local lt = easeOutQuad((t - 0.35) / 0.25)
        return lerpVec3(CAST_RAISE_POS, CAST_PUSH_POS, lt),
               CAST_RAISE_ROT:Slerp(CAST_PUSH_ROT, lt)
    else
        -- 弹性回位
        local lt = easeOutBack((t - 0.60) / 0.40)
        return lerpVec3(CAST_PUSH_POS, REST_POS, lt),
               CAST_PUSH_ROT:Slerp(REST_ROT, lt)
    end
end

-- ============================================================================
-- 公共接口
-- ============================================================================

--- 初始化
---@param sceneRef Scene
---@param camNode Node
function MagicWeaponView.Init(sceneRef, camNode)
    scene_ = sceneRef
    cameraNode_ = camNode
    currentWeaponId_ = nil
    activeModelId_ = nil
    animState_ = STATE_IDLE
    stateTimer_ = 0.0
    time_ = 0.0

    destroyCurrentModel()
    print("[MagicWeaponView] 魔法武器视图已初始化")
end

--- 重置动画状态
function MagicWeaponView.Reset()
    animState_ = STATE_IDLE
    stateTimer_ = 0.0
end

--- 设置当前武器（切换武器时调用，自动构建对应模型）
---@param weaponId string|nil nil=徒手
function MagicWeaponView.SetWeapon(weaponId)
    currentWeaponId_ = weaponId
    buildWeaponModel(weaponId)
    MagicWeaponView.Reset()
end

--- 设置可见性
---@param visible boolean
function MagicWeaponView.SetVisible(visible)
    if weaponPivot_ then
        weaponPivot_:SetEnabled(visible)
    end
end

--- 触发施法动画
function MagicWeaponView.TriggerCast()
    if animState_ == STATE_IDLE then
        animState_ = STATE_CAST
        stateTimer_ = 0.0
    end
end

--- 是否正在播放动画
---@return boolean
function MagicWeaponView.IsAnimating()
    return animState_ ~= STATE_IDLE
end

--- 每帧更新
---@param dt number
function MagicWeaponView.Update(dt)
    if not weaponPivot_ then return end

    time_ = time_ + dt

    local targetPos, targetRot

    if animState_ == STATE_IDLE then
        targetPos, targetRot = getIdlePose(time_)
    elseif animState_ == STATE_CAST then
        stateTimer_ = stateTimer_ + dt
        local t = math.min(stateTimer_ / CAST_DURATION, 1.0)
        targetPos, targetRot = getCastPose(t)
        if t >= 1.0 then
            animState_ = STATE_IDLE
            stateTimer_ = 0.0
        end
    end

    -- 平滑跟随
    local smoothSpeed = (animState_ == STATE_IDLE) and 8.0 or 16.0
    local s = math.min(1.0, smoothSpeed * dt)
    currentPos_ = lerpVec3(currentPos_, targetPos, s)
    currentRot_ = currentRot_:Slerp(targetRot, s)

    weaponPivot_.position = currentPos_
    weaponPivot_.rotation = currentRot_
end

return MagicWeaponView
