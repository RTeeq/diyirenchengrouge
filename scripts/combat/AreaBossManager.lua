-- ============================================================================
-- AreaBossManager.lua — 区域Boss管理器
-- 每局开始在固定位置刷新，击杀掉落唯一装备
-- 5种独特Boss造型，独立AI状态机
-- ============================================================================

local GameConfig = require("config.GameConfig")
local GameManager = require("core.GameManager")
local XPOrbManager = require("combat.XPOrbManager")
local EquipmentSystem = require("combat.EquipmentSystem")
local AudioManager = require("core.AudioManager")
local DifficultySystem = require("systems.DifficultySystem")

local AreaBossManager = {}

---@type Scene
local scene_ = nil
local getPlayerPos_ = nil

-- Boss 数据
local bosses_ = {}           -- { [bossId] = bossData }
-- 装备掉落物
local drops_ = {}            -- { [dropId] = dropData }
local nextDropId_ = 1

-- Boss 弹体
local projectiles_ = {}

-- 回调
local onBossDefeated_ = nil  -- function(bossKey, equipId)
local onEquipPickup_ = nil   -- function(equipId)

-- 前向声明
local fireBossProjectile
local spawnEquipDrop

-- ============================================================================
-- 辅助函数
-- ============================================================================

local function makeMat(color)
    return GameConfig.CreateMaterial(color)
end

local function makeGlow(color, intensity)
    return GameConfig.CreateEmissiveMaterial(color, intensity or 2.0)
end

local function distXZ(a, b)
    local dx, dz = a.x - b.x, a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end

--- 获取地面高度（射线检测）
local function getGroundY(x, z)
    if not scene_ then return 0 end
    local pw = scene_:GetComponent("PhysicsWorld")
    if not pw then return 0 end
    -- 只检测 Static 层，避免命中玩家/敌人碰撞体导致 Y 跳跃
    local result = pw:RaycastSingle(Ray(Vector3(x, 50, z), Vector3.DOWN), 100.0, CollisionLayerStatic)
    if result.body then
        return result.position.y
    end
    return 0
end

--- 设置Boss身体闪白/恢复原色
local function setBodyFlash(b, flash)
    local bodyNode = b.node:GetChild("Body")
    if not bodyNode then return end
    local mdl = bodyNode:GetComponent("StaticModel")
    if not mdl then return end
    if flash then
        mdl:SetMaterial(makeMat(Color(1, 1, 1, 1.0)))
    else
        mdl:SetMaterial(makeMat(b.bodyColor))
    end
end

-- ============================================================================
-- Boss 模型构建器（5种独特造型）
-- ============================================================================

--- 1. 翠木守卫：树人（圆柱树干 + 球形树冠 + 锥形树根 + 树枝 + 苔藓）
local function buildVerdantGuardian(node, cfg)
    local barkMat = makeMat(cfg.bodyColor)
    local leafMat = makeMat(cfg.accentColor)
    local rootMat = makeMat(Color(0.35, 0.22, 0.12, 1.0))

    -- 树干（下粗上细两段）
    local body = node:CreateChild("Body")
    local mdl = body:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    mdl:SetMaterial(barkMat)
    body.scale = Vector3(1.3, 2.0, 1.3)
    body.position = Vector3(0, 1.0, 0)

    local trunk2 = node:CreateChild("UpperTrunk")
    mdl = trunk2:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    mdl:SetMaterial(barkMat)
    trunk2.scale = Vector3(1.0, 1.2, 1.0)
    trunk2.position = Vector3(0, 2.6, 0)

    -- 树冠（三层球体，错开位置更自然）
    local crownData = {
        { scale = 2.5, y = 3.8, xz = 0 },
        { scale = 1.8, y = 4.3, xz = 0.6 },
        { scale = 1.6, y = 4.0, xz = -0.5 },
    }
    for i, cd in ipairs(crownData) do
        local crown = node:CreateChild("Crown" .. i)
        mdl = crown:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        mdl:SetMaterial(leafMat)
        crown.scale = Vector3(cd.scale, cd.scale * 0.8, cd.scale)
        crown.position = Vector3(cd.xz, cd.y, cd.xz * 0.3)
    end

    -- 发光核心（心脏）
    local core = node:CreateChild("Core")
    mdl = core:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    mdl:SetMaterial(makeGlow(cfg.glowColor, 3.0))
    core.scale = Vector3(0.4, 0.4, 0.4)
    core.position = Vector3(0, 2.0, 0.6)
    local pl = core:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = 6.0
    pl.color = cfg.glowColor
    pl.brightness = 2.0

    -- 双眼（树瘤中发光）
    local eyeMat = makeGlow(cfg.glowColor, 4.0)
    for _, side in ipairs({ -1, 1 }) do
        local eye = node:CreateChild("Eye")
        mdl = eye:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        mdl:SetMaterial(eyeMat)
        eye.scale = Vector3(0.12, 0.1, 0.08)
        eye.position = Vector3(0.25 * side, 2.8, 0.5)
    end

    -- 树枝手臂（两侧各一）
    for _, side in ipairs({ -1, 1 }) do
        local branch = node:CreateChild("Branch")
        mdl = branch:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        mdl:SetMaterial(barkMat)
        branch.scale = Vector3(0.2, 1.2, 0.2)
        branch.position = Vector3(0.8 * side, 2.2, 0)
        branch.rotation = Quaternion(50 * side, Vector3.FORWARD)

        -- 枝端叶球
        local leaf = node:CreateChild("BranchLeaf")
        mdl = leaf:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        mdl:SetMaterial(leafMat)
        leaf.scale = Vector3(0.5, 0.4, 0.5)
        leaf.position = Vector3(1.6 * side, 2.8, 0)
    end

    -- 树根（四个锥形，更粗壮）
    local rootOffsets = { {-0.6, -0.3}, {0.6, -0.3}, {-0.3, 0.6}, {0.3, -0.6} }
    for i, off in ipairs(rootOffsets) do
        local rt = node:CreateChild("Root" .. i)
        mdl = rt:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        mdl:SetMaterial(rootMat)
        rt.scale = Vector3(0.35, 0.7, 0.35)
        rt.position = Vector3(off[1], 0.1, off[2])
        rt.rotation = Quaternion(12 * (i % 2 == 0 and 1 or -1), Vector3.FORWARD)
    end

    -- 苔藓环（树干基部）
    local mossRing = node:CreateChild("MossRing")
    mdl = mossRing:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
    mdl:SetMaterial(makeMat(Color(0.15, 0.4, 0.1, 1.0)))
    mossRing.scale = Vector3(0.9, 0.9, 0.9)
    mossRing.position = Vector3(0, 0.15, 0)
end

--- 2. 岩魂巨像：石头巨人（方块身体/头/肢体 + 发光核心球 + 肩甲 + 腿）
local function buildStoneColossus(node, cfg)
    local stoneMat = makeMat(cfg.bodyColor)
    local darkStoneMat = makeMat(cfg.accentColor)

    -- 身体
    local body = node:CreateChild("Body")
    local mdl = body:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    mdl:SetMaterial(stoneMat)
    body.scale = Vector3(2.0, 2.2, 1.5)
    body.position = Vector3(0, 1.8, 0)

    -- 胸甲岩板
    local chestPlate = node:CreateChild("ChestPlate")
    mdl = chestPlate:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    mdl:SetMaterial(darkStoneMat)
    chestPlate.scale = Vector3(1.6, 1.2, 0.3)
    chestPlate.position = Vector3(0, 2.2, 0.7)

    -- 头
    local head = node:CreateChild("Head")
    mdl = head:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    mdl:SetMaterial(darkStoneMat)
    head.scale = Vector3(1.2, 1.0, 1.0)
    head.position = Vector3(0, 3.5, 0)

    -- 双眼（岩缝发光）
    local eyeMat = makeGlow(cfg.glowColor, 5.0)
    for _, side in ipairs({ -1, 1 }) do
        local eye = node:CreateChild("Eye")
        mdl = eye:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        mdl:SetMaterial(eyeMat)
        eye.scale = Vector3(0.2, 0.1, 0.08)
        eye.position = Vector3(0.25 * side, 3.6, 0.5)
    end

    -- 手臂（上臂+前臂+拳头）
    for _, side in ipairs({-1, 1}) do
        local upperArm = node:CreateChild("UpperArm")
        mdl = upperArm:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        mdl:SetMaterial(stoneMat)
        upperArm.scale = Vector3(0.65, 1.2, 0.65)
        upperArm.position = Vector3(side * 1.5, 2.3, 0)

        local foreArm = node:CreateChild("ForeArm")
        mdl = foreArm:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        mdl:SetMaterial(stoneMat)
        foreArm.scale = Vector3(0.55, 1.0, 0.55)
        foreArm.position = Vector3(side * 1.5, 1.1, 0.1)

        local fist = node:CreateChild("Fist")
        mdl = fist:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        mdl:SetMaterial(darkStoneMat)
        fist.scale = Vector3(0.5, 0.5, 0.5)
        fist.position = Vector3(side * 1.5, 0.5, 0.1)

        -- 肩甲
        local shoulder = node:CreateChild("Shoulder")
        mdl = shoulder:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        mdl:SetMaterial(darkStoneMat)
        shoulder.scale = Vector3(0.85, 0.3, 0.85)
        shoulder.position = Vector3(side * 1.5, 2.95, 0)
    end

    -- 双腿
    for _, side in ipairs({ -1, 1 }) do
        local leg = node:CreateChild("Leg")
        mdl = leg:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        mdl:SetMaterial(stoneMat)
        leg.scale = Vector3(0.7, 1.0, 0.7)
        leg.position = Vector3(side * 0.55, 0.2, 0)

        local foot = node:CreateChild("Foot")
        mdl = foot:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        mdl:SetMaterial(darkStoneMat)
        foot.scale = Vector3(0.8, 0.25, 1.0)
        foot.position = Vector3(side * 0.55, -0.35, 0.15)
    end

    -- 发光核心
    local core = node:CreateChild("Core")
    mdl = core:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    mdl:SetMaterial(makeGlow(cfg.glowColor, 4.0))
    core.scale = Vector3(0.5, 0.5, 0.5)
    core.position = Vector3(0, 2.0, 0.8)
    local pl = core:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = 8.0
    pl.color = cfg.glowColor
    pl.brightness = 2.5

    -- 背部岩刺
    for i = 1, 3 do
        local spike = node:CreateChild("BackSpike")
        mdl = spike:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        mdl:SetMaterial(darkStoneMat)
        spike.scale = Vector3(0.2, 0.5 + i * 0.1, 0.2)
        spike.position = Vector3((i - 2) * 0.5, 2.8, -0.8)
    end
end

--- 3. 幽影典狱长：幽灵（半透明多段身体 + 锁链 + 幽灵触手 + 冠冕）
local function buildPhantomWarden(node, cfg)
    local ghostMat = GameConfig.CreateAlphaMaterial(
        Color(cfg.bodyColor.r, cfg.bodyColor.g, cfg.bodyColor.b, 0.45))
    local accentMat = GameConfig.CreateAlphaMaterial(
        Color(cfg.accentColor.r, cfg.accentColor.g, cfg.accentColor.b, 0.55))
    local chainMat = makeMat(Color(0.25, 0.25, 0.3, 1.0))

    -- 下半身（渐隐锥体）
    local lower = node:CreateChild("LowerBody")
    local mdl = lower:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
    mdl:SetMaterial(GameConfig.CreateAlphaMaterial(
        Color(cfg.bodyColor.r, cfg.bodyColor.g, cfg.bodyColor.b, 0.3)))
    lower.scale = Vector3(1.4, 2.0, 1.4)
    lower.position = Vector3(0, 1.0, 0)
    lower.rotation = Quaternion(180, Vector3.RIGHT)

    -- 上半身
    local body = node:CreateChild("Body")
    mdl = body:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    mdl:SetMaterial(ghostMat)
    body.scale = Vector3(0.9, 1.5, 0.9)
    body.position = Vector3(0, 2.5, 0)

    -- 肩甲
    local upperBody = node:CreateChild("UpperBody")
    mdl = upperBody:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    mdl:SetMaterial(accentMat)
    upperBody.scale = Vector3(1.1, 0.4, 1.1)
    upperBody.position = Vector3(0, 3.2, 0)

    -- 头部
    local head = node:CreateChild("Head")
    mdl = head:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    mdl:SetMaterial(accentMat)
    head.scale = Vector3(0.8, 0.9, 0.8)
    head.position = Vector3(0, 3.8, 0)

    -- 幽灵冠冕（3根尖刺）
    for i = 1, 3 do
        local spike = node:CreateChild("CrownSpike" .. i)
        mdl = spike:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        mdl:SetMaterial(makeGlow(cfg.glowColor, 2.5))
        spike.scale = Vector3(0.08, 0.4, 0.08)
        local ang = math.rad((i - 1) * 120)
        spike.position = Vector3(math.sin(ang) * 0.3, 4.4, math.cos(ang) * 0.3)
    end

    -- 双眼（发光）
    for i, side in ipairs({-1, 1}) do
        local eye = node:CreateChild("Eye" .. i)
        mdl = eye:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        mdl:SetMaterial(makeGlow(cfg.glowColor, 5.0))
        eye.scale = Vector3(0.12, 0.12, 0.12)
        eye.position = Vector3(side * 0.2, 3.85, 0.35)
    end
    -- 主光源
    local eyeLight = node:CreateChild("EyeLight")
    local pl = eyeLight:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = 6.0
    pl.color = cfg.glowColor
    pl.brightness = 3.0
    eyeLight.position = Vector3(0, 3.85, 0.35)

    -- 幽灵手臂（半透明圆柱）
    for i, side in ipairs({-1, 1}) do
        local arm = node:CreateChild("Arm" .. i)
        mdl = arm:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        mdl:SetMaterial(ghostMat)
        arm.scale = Vector3(0.18, 1.2, 0.18)
        arm.position = Vector3(side * 0.9, 2.8, 0)
        arm.rotation = Quaternion(side * 25, Vector3.FORWARD)

        -- 手掌（发光球）
        local hand = node:CreateChild("Hand" .. i)
        mdl = hand:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        mdl:SetMaterial(makeGlow(cfg.glowColor, 2.0))
        hand.scale = Vector3(0.2, 0.2, 0.2)
        hand.position = Vector3(side * 1.2, 2.0, 0)
    end

    -- 锁链环（Torus）×4
    for i = 1, 4 do
        local chain = node:CreateChild("Chain" .. i)
        mdl = chain:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
        mdl:SetMaterial(chainMat)
        chain.scale = Vector3(0.7 + i * 0.15, 0.7 + i * 0.15, 0.7 + i * 0.15)
        chain.position = Vector3(0, 0.6 + i * 0.55, 0)
        chain.rotation = Quaternion(25 * i, Vector3.UP)
    end

    -- 幽灵触手（从底部伸出）
    for i = 1, 3 do
        local tendril = node:CreateChild("Tendril" .. i)
        mdl = tendril:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        mdl:SetMaterial(GameConfig.CreateAlphaMaterial(
            Color(cfg.glowColor.r, cfg.glowColor.g, cfg.glowColor.b, 0.3)))
        tendril.scale = Vector3(0.06, 1.0 + i * 0.2, 0.06)
        local ang = math.rad((i - 1) * 120 + 60)
        tendril.position = Vector3(math.sin(ang) * 0.5, 0.2, math.cos(ang) * 0.5)
        tendril.rotation = Quaternion(15 * i, Vector3.FORWARD)
    end
end

--- 4. 焦土蛟蛇：多节蛇身（5段 + 头 + 鳞甲 + 鳍 + 爪 + 火焰尾巴）
local function buildScorchedWyrm(node, cfg)
    local bodyMat = makeMat(cfg.bodyColor)
    local accentMat = makeMat(cfg.accentColor)
    local scaleMat = makeMat(Color(
        cfg.bodyColor.r * 0.7, cfg.bodyColor.g * 0.7, cfg.bodyColor.b * 0.7, 1.0))

    -- 蛇身（5段圆柱，蜿蜒曲线）
    for i = 1, 5 do
        local seg = node:CreateChild("Seg" .. i)
        local mdl = seg:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        mdl:SetMaterial(bodyMat)
        local s = 0.85 - (i - 1) * 0.1
        seg.scale = Vector3(s, 1.0, s)
        local angle = math.rad((i - 1) * 20)
        seg.position = Vector3(
            math.sin(angle) * (i - 1) * 0.7,
            0.5 + (i - 1) * 0.25,
            -math.cos(angle) * (i - 1) * 0.7
        )
        seg.rotation = Quaternion((i - 1) * 12, Vector3.RIGHT)

        -- 鳞甲条（每段背部）
        local scaleN = node:CreateChild("Scale" .. i)
        mdl = scaleN:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        mdl:SetMaterial(scaleMat)
        scaleN.scale = Vector3(s * 0.6, 0.08, s * 0.3)
        scaleN.position = seg.position + Vector3(0, s * 0.5 + 0.05, 0)
    end

    -- 头部（锥形）
    local head = node:CreateChild("Head")
    local mdl = head:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
    mdl:SetMaterial(accentMat)
    head.scale = Vector3(0.7, 1.5, 0.7)
    head.position = Vector3(0.8, 1.8, -1.2)
    head.rotation = Quaternion(-45, Vector3.RIGHT)

    -- 下颚
    local jaw = node:CreateChild("Jaw")
    mdl = jaw:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    mdl:SetMaterial(accentMat)
    jaw.scale = Vector3(0.4, 0.15, 0.6)
    jaw.position = Vector3(0.8, 1.5, -1.4)
    jaw.rotation = Quaternion(-40, Vector3.RIGHT)

    -- 双眼
    for i, side in ipairs({-1, 1}) do
        local eye = node:CreateChild("Eye" .. i)
        mdl = eye:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        mdl:SetMaterial(makeGlow(cfg.glowColor, 4.0))
        eye.scale = Vector3(0.12, 0.12, 0.12)
        eye.position = Vector3(0.8 + side * 0.2, 2.2, -1.1)
    end
    -- 头部光源
    local headLight = node:CreateChild("HeadLight")
    local pl = headLight:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = 7.0
    pl.color = cfg.glowColor
    pl.brightness = 2.5
    headLight.position = Vector3(0.8, 2.2, -1.1)

    -- 角（头顶双角）
    for i, side in ipairs({-1, 1}) do
        local horn = node:CreateChild("Horn" .. i)
        mdl = horn:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        mdl:SetMaterial(accentMat)
        horn.scale = Vector3(0.1, 0.5, 0.1)
        horn.position = Vector3(0.8 + side * 0.25, 2.6, -1.3)
        horn.rotation = Quaternion(side * 15, Vector3.FORWARD)
    end

    -- 背鳍（4片，沿脊柱）
    for i = 1, 4 do
        local fin = node:CreateChild("Fin" .. i)
        mdl = fin:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        mdl:SetMaterial(makeGlow(cfg.glowColor, 2.0))
        fin.scale = Vector3(0.12, 0.5 + i * 0.08, 0.12)
        local angle = math.rad((i - 1) * 18)
        fin.position = Vector3(
            math.sin(angle) * (i - 1) * 0.5,
            1.3 + (i - 1) * 0.15,
            -math.cos(angle) * (i - 1) * 0.5
        )
    end

    -- 小爪（两对，身体两侧）
    for i, side in ipairs({-1, 1}) do
        for j = 1, 2 do
            local claw = node:CreateChild("Claw" .. i .. "_" .. j)
            mdl = claw:CreateComponent("StaticModel")
            mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
            mdl:SetMaterial(bodyMat)
            claw.scale = Vector3(0.08, 0.4, 0.08)
            claw.position = Vector3(
                side * 0.5,
                0.3 + (j - 1) * 0.8,
                -(j - 1) * 0.6
            )
            claw.rotation = Quaternion(side * 45, Vector3.FORWARD)
        end
    end

    -- 尾巴火焰（发光球）
    local tailFire = node:CreateChild("TailFire")
    mdl = tailFire:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    mdl:SetMaterial(makeGlow(cfg.glowColor, 3.5))
    tailFire.scale = Vector3(0.35, 0.35, 0.35)
    local lastAngle = math.rad(4 * 20)
    tailFire.position = Vector3(
        math.sin(lastAngle) * 4 * 0.7,
        0.5 + 4 * 0.25,
        -math.cos(lastAngle) * 4 * 0.7
    )
end

--- 5. 庙堂魔：鬼面武士（多层铠甲 + 面具 + 武器 + 肩甲 + 双光环）
local function buildShrineDemon(node, cfg)
    local bodyMat = makeMat(cfg.bodyColor)
    local accentMat = makeMat(cfg.accentColor)
    local darkMat = makeMat(Color(
        cfg.bodyColor.r * 0.5, cfg.bodyColor.g * 0.5, cfg.bodyColor.b * 0.5, 1.0))

    -- 下半身铠甲（腰带以下）
    local lower = node:CreateChild("LowerBody")
    local mdl = lower:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    mdl:SetMaterial(bodyMat)
    lower.scale = Vector3(1.6, 1.2, 1.1)
    lower.position = Vector3(0, 0.6, 0)

    -- 上半身铠甲
    local body = node:CreateChild("Body")
    mdl = body:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    mdl:SetMaterial(bodyMat)
    body.scale = Vector3(1.8, 1.5, 1.2)
    body.position = Vector3(0, 2.0, 0)

    -- 胸甲装饰
    local chest = node:CreateChild("ChestPlate")
    mdl = chest:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    mdl:SetMaterial(darkMat)
    chest.scale = Vector3(1.2, 0.8, 0.15)
    chest.position = Vector3(0, 2.2, 0.55)

    -- 腰带
    local belt = node:CreateChild("Belt")
    mdl = belt:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    mdl:SetMaterial(accentMat)
    belt.scale = Vector3(1.0, 0.15, 1.0)
    belt.position = Vector3(0, 1.25, 0)

    -- 头部（鬼面）
    local head = node:CreateChild("Head")
    mdl = head:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    mdl:SetMaterial(accentMat)
    head.scale = Vector3(1.0, 0.9, 0.8)
    head.position = Vector3(0, 3.2, 0)

    -- 面具纹路（额头横条）
    local mask = node:CreateChild("MaskStripe")
    mdl = mask:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    mdl:SetMaterial(darkMat)
    mask.scale = Vector3(0.8, 0.1, 0.1)
    mask.position = Vector3(0, 3.5, 0.35)

    -- 双角（更大）
    for i, side in ipairs({-1, 1}) do
        local horn = node:CreateChild("Horn" .. i)
        mdl = horn:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        mdl:SetMaterial(makeGlow(cfg.glowColor, 3.0))
        horn.scale = Vector3(0.2, 1.0, 0.2)
        horn.position = Vector3(side * 0.4, 3.9, 0)
        horn.rotation = Quaternion(side * 25, Vector3.FORWARD)
    end

    -- 双眼（发光）
    for i, side in ipairs({-1, 1}) do
        local eye = node:CreateChild("Eye" .. i)
        mdl = eye:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        mdl:SetMaterial(makeGlow(cfg.glowColor, 5.0))
        eye.scale = Vector3(0.12, 0.12, 0.12)
        eye.position = Vector3(side * 0.25, 3.3, 0.38)
    end
    -- 主光源
    local eyeLight = node:CreateChild("EyeLight")
    local pl = eyeLight:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = 8.0
    pl.color = cfg.glowColor
    pl.brightness = 3.0
    eyeLight.position = Vector3(0, 3.3, 0.38)

    -- 肩甲（双侧）
    for i, side in ipairs({-1, 1}) do
        local shoulder = node:CreateChild("Shoulder" .. i)
        mdl = shoulder:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        mdl:SetMaterial(darkMat)
        shoulder.scale = Vector3(0.5, 0.4, 0.5)
        shoulder.position = Vector3(side * 1.2, 2.7, 0)

        -- 肩刺
        local spike = node:CreateChild("ShoulderSpike" .. i)
        mdl = spike:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        mdl:SetMaterial(accentMat)
        spike.scale = Vector3(0.12, 0.4, 0.12)
        spike.position = Vector3(side * 1.2, 3.1, 0)
    end

    -- 手臂（双侧）
    for i, side in ipairs({-1, 1}) do
        local arm = node:CreateChild("Arm" .. i)
        mdl = arm:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        mdl:SetMaterial(bodyMat)
        arm.scale = Vector3(0.2, 1.0, 0.2)
        arm.position = Vector3(side * 1.2, 1.8, 0)
        arm.rotation = Quaternion(side * 10, Vector3.FORWARD)

        -- 拳头
        local fist = node:CreateChild("Fist" .. i)
        mdl = fist:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        mdl:SetMaterial(bodyMat)
        fist.scale = Vector3(0.25, 0.25, 0.25)
        fist.position = Vector3(side * 1.3, 1.0, 0)
    end

    -- 右手武器（太刀 - 长方块）
    local weapon = node:CreateChild("Weapon")
    mdl = weapon:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    mdl:SetMaterial(makeGlow(cfg.glowColor, 1.5))
    weapon.scale = Vector3(0.08, 2.0, 0.2)
    weapon.position = Vector3(1.5, 1.5, 0.3)
    weapon.rotation = Quaternion(-30, Vector3.FORWARD)

    -- 腿部（双侧）
    for i, side in ipairs({-1, 1}) do
        local leg = node:CreateChild("Leg" .. i)
        mdl = leg:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        mdl:SetMaterial(darkMat)
        leg.scale = Vector3(0.25, 0.6, 0.25)
        leg.position = Vector3(side * 0.4, 0.0, 0)
    end

    -- 双光环（Torus）
    local aura1 = node:CreateChild("Aura1")
    mdl = aura1:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
    mdl:SetMaterial(makeGlow(cfg.glowColor, 2.0))
    aura1.scale = Vector3(2.0, 2.0, 2.0)
    aura1.position = Vector3(0, 0.5, 0)

    local aura2 = node:CreateChild("Aura2")
    mdl = aura2:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
    mdl:SetMaterial(makeGlow(cfg.glowColor, 1.5))
    aura2.scale = Vector3(1.5, 1.5, 1.5)
    aura2.position = Vector3(0, 2.0, 0)
    aura2.rotation = Quaternion(90, Vector3.RIGHT)

    -- 背后旗帜（战旗）
    local banner = node:CreateChild("Banner")
    mdl = banner:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    mdl:SetMaterial(accentMat)
    banner.scale = Vector3(0.6, 1.5, 0.05)
    banner.position = Vector3(0, 3.5, -0.7)

    -- 旗杆
    local pole = node:CreateChild("BannerPole")
    mdl = pole:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    mdl:SetMaterial(darkMat)
    pole.scale = Vector3(0.05, 2.5, 0.05)
    pole.position = Vector3(0, 2.5, -0.7)
end

--- 构建器映射
local MODEL_BUILDERS = {
    verdant_guardian = buildVerdantGuardian,
    stone_colossus   = buildStoneColossus,
    phantom_warden   = buildPhantomWarden,
    scorched_wyrm    = buildScorchedWyrm,
    shrine_demon     = buildShrineDemon,
}

-- ============================================================================
-- Boss 生成
-- ============================================================================

--- 生成所有区域Boss（每局开始调用一次）
function AreaBossManager.SpawnAll()
    if not scene_ then return end

    for _, bossKey in ipairs(GameConfig.AreaBossOrder) do
        local cfg = GameConfig.AreaBosses[bossKey]
        if not cfg then goto continue end

        local bossId = "areaBoss_" .. bossKey
        -- 跳过已存在的
        if bosses_[bossId] then goto continue end

        local groundY = getGroundY(cfg.spawnPos.x, cfg.spawnPos.z)
        local node = scene_:CreateChild(bossId)
        node.position = Vector3(cfg.spawnPos.x, groundY, cfg.spawnPos.z)
        node:SetVar("EnemyId", Variant(bossId))

        -- 构建模型
        local builder = MODEL_BUILDERS[bossKey]
        if builder then
            builder(node, cfg)
        end

        -- 添加 Kinematic 物理体（阻挡玩家）
        do
            local rb = node:CreateComponent("RigidBody")
            rb.mass = 0
            rb.kinematic = true
            rb.collisionLayer = CollisionLayerKinematic
            rb.collisionMask = CollisionMaskKinematic
            rb.friction = 0.3
            local cs = node:CreateComponent("CollisionShape")
            cs:SetCapsule(1.2, 3.6, Vector3(0, 1.8, 0))
        end

        -- 难度视觉特效：困难/炼狱模式给Boss添加发光光环
        local diffGlow = DifficultySystem.GetGlowIntensity()
        if diffGlow > 0 then
            local gc = DifficultySystem.GetGlowColor()
            local auraNode = node:CreateChild("DiffAura")
            auraNode.scale = Vector3(2.0, 2.0, 2.0)
            auraNode.position = Vector3(0, 1.8, 0)
            local auraMdl = auraNode:CreateComponent("StaticModel")
            auraMdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
            auraMdl:SetMaterial(makeGlow(Color(gc[1], gc[2], gc[3], 0.25), diffGlow))
        end

        -- 难度缩放
        local bossHP = math.floor(cfg.hp * DifficultySystem.GetBossHPMult())
        local bossDmg = math.floor(cfg.damage * DifficultySystem.GetBossDmgMult())

        -- Boss 数据
        bosses_[bossId] = {
            id = bossId,
            key = bossKey,
            node = node,
            hp = bossHP,
            maxHP = bossHP,
            damage = bossDmg,
            attackRange = cfg.attackRange,
            detectRange = cfg.detectRange,
            chaseSpeed = cfg.chaseSpeed,
            attackCooldown = cfg.attackCooldown,
            attackTimer = 0,
            state = "DORMANT",    -- DORMANT → CHASE → ATTACK
            bodyColor = cfg.bodyColor,
            flashTimer = 0,
            cfg = cfg,
            rotAngle = 0,         -- 待机旋转
        }

        print("[AreaBossManager] 生成区域Boss: " .. cfg.name .. " @ (" .. cfg.spawnPos.x .. ", " .. cfg.spawnPos.z .. ")")
        ::continue::
    end
end

-- ============================================================================
-- AI 更新
-- ============================================================================

local function updateBossAI(b, dt, playerPos)
    local dist = distXZ(b.node.position, playerPos)

    if b.state == "DORMANT" then
        -- 待机：缓慢旋转
        b.rotAngle = (b.rotAngle or 0) + dt * 20
        b.node.rotation = Quaternion(b.rotAngle, Vector3.UP)

        if dist < b.detectRange then
            b.state = "CHASE"
        end

    elseif b.state == "CHASE" then
        -- 追击玩家
        if dist > b.detectRange * 1.5 then
            b.state = "DORMANT"
            return
        end

        local dir = (playerPos - b.node.position):Normalized()
        local moveSpeed = b.chaseSpeed * dt
        local pos = b.node.position
        local newPos = pos + Vector3(dir.x * moveSpeed, 0, dir.z * moveSpeed)
        local targetY = getGroundY(newPos.x, newPos.z)
        -- 平滑修正 Y，避免瞬间跳跃
        local diffY = targetY - pos.y
        if math.abs(diffY) < 0.05 then
            newPos.y = pos.y  -- 死区，不修正
        elseif math.abs(diffY) < 3.0 then
            newPos.y = pos.y + diffY * math.min(1.0, 10.0 * dt)
        else
            newPos.y = targetY  -- 大偏差立即修正
        end
        -- 防止碰撞体重叠：与玩家保持最小安全距离（Boss半径 + 玩家半径 + 余量）
        local safeRadius = 0.6 + 0.4 + 0.2
        local newDist = math.sqrt((newPos.x - playerPos.x)^2 + (newPos.z - playerPos.z)^2)
        if newDist >= safeRadius then
            b.node.position = newPos
        end

        -- 面向玩家
        local angle = math.deg(math.atan(dir.x, dir.z))
        b.node.rotation = Quaternion(angle, Vector3.UP)

        if dist < b.attackRange then
            b.state = "ATTACK"
            b.attackTimer = 0
        end

    elseif b.state == "ATTACK" then
        if dist > b.attackRange * 1.5 then
            b.state = "CHASE"
            return
        end

        -- 面向玩家
        local dir = (playerPos - b.node.position):Normalized()
        local angle = math.deg(math.atan(dir.x, dir.z))
        b.node.rotation = Quaternion(angle, Vector3.UP)

        b.attackTimer = b.attackTimer + dt
        if b.attackTimer >= b.attackCooldown then
            b.attackTimer = 0
            -- 发射弹体攻击
            fireBossProjectile(b, playerPos)
        end
    end
end

-- ============================================================================
-- Boss 弹体
-- ============================================================================

fireBossProjectile = function(b, targetPos)
    if not scene_ then return end
    local startPos = b.node.position + Vector3(0, 2.0, 0)
    local dir = (targetPos + Vector3(0, 1.0, 0) - startPos):Normalized()

    local node = scene_:CreateChild("BossProjectile")
    node.position = startPos
    local mdl = node:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    mdl:SetMaterial(makeGlow(b.cfg.glowColor, 3.0))
    node.scale = Vector3(0.35, 0.35, 0.35)
    local pl = node:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = 4.0
    pl.color = b.cfg.glowColor
    pl.brightness = 2.0

    table.insert(projectiles_, {
        node = node, dir = dir, speed = 10.0,
        damage = b.damage, life = 4.0,
    })
end

local function updateProjectiles(dt, playerPos)
    local PlayerHealth = require("combat.PlayerHealth")
    local toRemove = {}

    for i, p in ipairs(projectiles_) do
        p.life = p.life - dt
        if p.life <= 0 then
            table.insert(toRemove, i)
        else
            p.node.position = p.node.position + p.dir * p.speed * dt
            -- 命中玩家检测
            local dist = (p.node.position - playerPos):Length()
            if dist < 1.5 then
                PlayerHealth.TakeDamage(p.damage)
                table.insert(toRemove, i)
            end
        end
    end

    for i = #toRemove, 1, -1 do
        local idx = toRemove[i]
        if projectiles_[idx].node then
            projectiles_[idx].node:Remove()
        end
        table.remove(projectiles_, idx)
    end
end

-- ============================================================================
-- 受伤 / 死亡
-- ============================================================================

--- 对区域Boss造成伤害
---@param bossId string
---@param damage number
function AreaBossManager.DamageAreaBoss(bossId, damage)
    local b = bosses_[bossId]
    if not b then return end

    -- 装备伤害加成
    local dmgMult = EquipmentSystem.GetDamageMult()
    local finalDmg = math.floor(damage * dmgMult)

    b.hp = b.hp - finalDmg
    b.flashTimer = 0.15
    setBodyFlash(b, true)

    if b.hp <= 0 then
        -- Boss 击杀
        local pos = b.node.position

        -- 掉落经验球
        XPOrbManager.SpawnOrbs(pos, GameConfig.Leveling.OrbsBoss, 1)

        -- 掉落装备
        local equipId = b.cfg.dropEquip
        if equipId and not EquipmentSystem.HasEquipped(equipId) then
            spawnEquipDrop(pos, equipId, b.key)
        end

        -- 移除Boss节点
        b.node:Remove()
        bosses_[bossId] = nil

        -- 回调
        if onBossDefeated_ then
            onBossDefeated_(b.key, equipId)
        end

        print("[AreaBossManager] 区域Boss击败: " .. b.cfg.name)
    end
end

-- ============================================================================
-- 装备掉落物
-- ============================================================================

spawnEquipDrop = function(pos, equipId, bossKey)
    if not scene_ then return end
    local ecfg = GameConfig.Equipment[equipId]
    if not ecfg then return end

    local dropId = "equipDrop_" .. nextDropId_
    nextDropId_ = nextDropId_ + 1

    local groundY = getGroundY(pos.x, pos.z)
    local node = scene_:CreateChild(dropId)
    node.position = Vector3(pos.x, groundY + 1.0, pos.z)
    node:SetVar("InteractType", Variant("equipment"))
    node:SetVar("EquipId", Variant(equipId))

    -- 发光球体
    local orb = node:CreateChild("Orb")
    local mdl = orb:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    mdl:SetMaterial(makeGlow(ecfg.overlayColor, 3.0))
    orb.scale = Vector3(0.5, 0.5, 0.5)

    -- 光环
    local ring = node:CreateChild("Ring")
    mdl = ring:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
    mdl:SetMaterial(makeGlow(ecfg.overlayColor, 2.0))
    ring.scale = Vector3(0.8, 0.8, 0.8)

    -- 光源
    local pl = node:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = 8.0
    pl.color = ecfg.overlayColor
    pl.brightness = 3.0

    drops_[dropId] = {
        id = dropId,
        node = node,
        equipId = equipId,
        rotAngle = 0,
        floatPhase = math.random() * 6.28,
        baseY = groundY + 1.0,
    }

    print("[AreaBossManager] 装备掉落: " .. ecfg.name .. " @ (" .. pos.x .. ", " .. pos.z .. ")")
end

local function updateDrops(dt, playerPos)
    local toRemove = {}

    for id, d in pairs(drops_) do
        -- 浮动旋转动画
        d.rotAngle = d.rotAngle + dt * 90
        d.floatPhase = d.floatPhase + dt * 2.0
        d.node.rotation = Quaternion(d.rotAngle, Vector3.UP)
        d.node.position = Vector3(
            d.node.position.x,
            d.baseY + math.sin(d.floatPhase) * 0.3,
            d.node.position.z
        )

        -- 自动拾取检测
        local dist = distXZ(d.node.position, playerPos)
        if dist < 2.0 then
            -- 装备
            local slot = EquipmentSystem.Equip(d.equipId)
            if slot > 0 then
                if onEquipPickup_ then
                    onEquipPickup_(d.equipId)
                end
                -- 音效
                if AudioManager and AudioManager.PlayItemPickup then
                    AudioManager.PlayItemPickup()
                end
            end
            table.insert(toRemove, id)
        end
    end

    for _, id in ipairs(toRemove) do
        if drops_[id] and drops_[id].node then
            drops_[id].node:Remove()
        end
        drops_[id] = nil
    end
end

-- ============================================================================
-- 公共接口
-- ============================================================================

---@param scn Scene
---@param getPos function
function AreaBossManager.Init(scn, getPos)
    scene_ = scn
    getPlayerPos_ = getPos
    bosses_ = {}
    drops_ = {}
    projectiles_ = {}
    nextDropId_ = 1
    print("[AreaBossManager] 初始化完成")
end

--- 是否是区域Boss ID
---@param enemyId string
---@return boolean
function AreaBossManager.IsAreaBoss(enemyId)
    if type(enemyId) ~= "string" then return false end
    return enemyId:sub(1, 9) == "areaBoss_"
end

--- 获取最近区域Boss的血量（供HUD显示）
---@param playerPos Vector3
---@return number|nil hp
---@return number|nil maxHP
---@return string|nil name
function AreaBossManager.GetNearestBossHP(playerPos)
    local nearest = nil
    local nearDist = 999
    for _, b in pairs(bosses_) do
        local d = distXZ(b.node.position, playerPos)
        if d < b.detectRange and d < nearDist then
            nearDist = d
            nearest = b
        end
    end
    if nearest then
        return nearest.hp, nearest.maxHP, nearest.cfg.icon .. " " .. nearest.cfg.name
    end
    return nil, nil, nil
end

--- 设置Boss击败回调
---@param cb function(bossKey, equipId)
function AreaBossManager.OnBossDefeated(cb)
    onBossDefeated_ = cb
end

--- 设置装备拾取回调
---@param cb function(equipId)
function AreaBossManager.OnEquipPickup(cb)
    onEquipPickup_ = cb
end

---@param dt number
function AreaBossManager.Update(dt)
    if not scene_ then return end
    local playerPos = getPlayerPos_()

    -- 更新所有Boss AI
    for id, b in pairs(bosses_) do
        -- 闪白恢复
        if b.flashTimer > 0 then
            b.flashTimer = b.flashTimer - dt
            if b.flashTimer <= 0 then
                setBodyFlash(b, false)
            end
        end
        updateBossAI(b, dt, playerPos)
    end

    -- 更新弹体
    updateProjectiles(dt, playerPos)

    -- 更新掉落物
    updateDrops(dt, playerPos)
end

function AreaBossManager.Reset()
    -- 清理Boss
    for _, b in pairs(bosses_) do
        if b.node then b.node:Remove() end
    end
    bosses_ = {}

    -- 清理掉落物
    for _, d in pairs(drops_) do
        if d.node then d.node:Remove() end
    end
    drops_ = {}

    -- 清理弹体
    for _, p in ipairs(projectiles_) do
        if p.node then p.node:Remove() end
    end
    projectiles_ = {}
    nextDropId_ = 1

    print("[AreaBossManager] 已重置")
end

--- 获取所有存活Boss数据（供调试）
---@return table
function AreaBossManager.GetAllBosses()
    return bosses_
end

return AreaBossManager
