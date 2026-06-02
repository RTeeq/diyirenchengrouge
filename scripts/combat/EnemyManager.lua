-- ============================================================================
-- EnemyManager.lua — 敌人管理器
-- 近战 (暗影兽) / 远程 (邪灵) AI、弹幕、玩家攻击
-- ============================================================================

local GameConfig = require("config.GameConfig")
local PlayerHealth = require("combat.PlayerHealth")
local XPOrbManager = require("combat.XPOrbManager")
local AudioManager = require("core.AudioManager")
local SafeZoneSystem = require("world.SafeZoneSystem")
local DifficultySystem = require("systems.DifficultySystem")

-- 精英怪类型判断
local function isEliteType(enemyType)
    return string.sub(enemyType or "", 1, 5) == "elite"
end

-- 击杀货币奖励（统一逻辑）
---@param e table 敌人数据
local function applyKillReward(e)
    local GM = require("core.GameManager")
    local level = e.monsterLvl or 1
    local gold, crystal = 0, 0

    if e.isBoss then
        gold = 1000 + level * 80
        crystal = 3
    elseif isEliteType(e.type) then
        gold = 250 + level * 20
        crystal = 1
    else
        gold = 25 + level * 5
        crystal = (math.random() < 0.15) and 1 or 0
    end

    -- 难度倍率
    local goldMult = DifficultySystem.GetGoldMult()
    gold = math.floor(gold * goldMult)
    crystal = math.floor(crystal * goldMult)

    -- 金币水晶不再立即入账，仅记录到出征数据
    -- 结算回安全区时统一发放，死亡则丢失本次出征收益
    SafeZoneSystem.RecordKill(gold, crystal)
end

local EnemyManager = {}

---@type Scene
local scene_ = nil
local enemies_ = {}
local projectiles_ = {}
local nextId_ = 1

local playerGetPos_ = nil
local playerGetCamNode_ = nil

-- 波次刷怪状态（时间驱动）
local smallWaveTimer_ = 0     -- 小波倒计时（15秒）
local bigWaveTimer_ = 0       -- 大波倒计时（60秒）
local upgradeTimer_ = 0       -- 怪物升级倒计时（180秒）
local bossTimer_ = 0          -- Boss 倒计时（600秒）
local waveNumber_ = 0         -- 累计波数
local bossCount_ = 0          -- 已生成 Boss 数

-- 怪物等级（每3分钟自增，独立于玩家等级）
local monsterLevel_ = 1

-- Boss 跟踪（用于 UI 显示血量）
local activeBossId_ = nil     -- 当前存活的定时 Boss ID
local activeDragonId_ = nil   -- 当前存活的龙 Boss ID
local activeUltimateBossId_ = nil  -- 当前存活的终极 Boss ID
local onBossDefeated_ = nil   -- Boss 击败回调
local onDragonDefeated_ = nil -- 龙Boss 击败回调
local onUltimateDefeated_ = nil -- 终极Boss 击败回调
local onUltimateSpawned_ = nil -- 终极Boss 生成通知回调
local ultimateBossTimer_ = 0  -- 终极Boss 计时器（1200秒=20分钟）

-- 游戏全局经过时间（用于精英怪阶段解锁）
local gameElapsed_ = 0

-- 敌人死亡回调（掉落系统使用）
local onEnemyDeath_ = nil     -- function(enemyData, position)

-- 统计
local killCount_ = 0          -- 本局击杀数

-- 血包掉落
local healthPacks_ = {}       -- { node, life, phase }
local nextHPId_ = 1

-- 场景敌人总数上限（防止 "View exceeds maximum limit"）
local MAX_ALIVE_ENEMIES = 40

--- 统计当前存活敌人数量
---@return integer
local function getEnemyCount()
    local n = 0
    for _ in pairs(enemies_) do n = n + 1 end
    return n
end

--- 根据游戏已过时间选择精英怪类型
---@return string
local function pickEliteType()
    local waveCfg = GameConfig.Enemies.Wave
    local pool = { "eliteMelee", "eliteRanged" }
    if gameElapsed_ >= (waveCfg.EliteAOEUnlockTime or 600) then
        table.insert(pool, "eliteAOE")
    end
    if gameElapsed_ >= (waveCfg.EliteDebuffUnlockTime or 900) then
        table.insert(pool, "eliteDebuff")
    end
    return pool[math.random(1, #pool)]
end

-- ============================================================================
-- 工具函数
-- ============================================================================

--- 获取地面高度，射线未命中时返回 fallbackY（默认 nil 表示未命中）
local function getGroundY(x, z, fallbackY)
    local pw = scene_:GetComponent("PhysicsWorld")
    if not pw then return fallbackY end
    -- 从较低起点（3米高）向下检测，避免命中建筑屋顶导致敌人跳到楼顶
    -- 敌人都是地面单位，脚底 Y 通常在 0 附近，3 米足够覆盖地形起伏
    local startY = 3.0
    if fallbackY and fallbackY > startY then startY = fallbackY + 2.0 end
    local result = pw:RaycastSingle(Ray(Vector3(x, startY, z), Vector3.DOWN), startY + 5.0, CollisionLayerStatic)
    if result.body then return result.position.y end
    return fallbackY
end

--- 平滑修正 Y 到目标地面高度（避免瞬间 snap 导致跳动）
--- @param e table 敌人数据
--- @param targetY number 目标 Y
--- @param dt number 帧时间（nil 表示立即 snap）
local function smoothCorrectY(e, targetY, dt)
    local pos = e.node.position
    local diff = targetY - pos.y
    -- 死区：偏差小于 0.05 不修正，避免微抖动
    if math.abs(diff) < 0.05 then return end
    if dt and math.abs(diff) < 3.0 then
        -- 小偏差用平滑插值
        local newY = pos.y + diff * math.min(1.0, 10.0 * dt)
        e.node.position = Vector3(pos.x, newY, pos.z)
    else
        -- 大偏差立即修正
        e.node.position = Vector3(pos.x, targetY, pos.z)
    end
end

--- Y 边界钳制：防止敌人飞天或掉入地下
--- 如果当前 Y 与 spawnPos.y 偏差超过阈值，强制修正
local MAX_Y_DRIFT = 5.0  -- 允许的最大 Y 偏差（米）
local function clampEnemyY(e)
    if not e.spawnPos then return end
    local pos = e.node.position
    local baseY = e.spawnPos.y
    -- 龙Boss等飞行怪有额外高度
    if e.type == "dragonBoss" then
        local dCfg = GameConfig.Enemies.DragonBoss
        baseY = baseY + (dCfg and dCfg.FlyHeight or 4.0)
    end
    if math.abs(pos.y - baseY) > MAX_Y_DRIFT then
        local correctedY = getGroundY(pos.x, pos.z, baseY)
        if e.type == "dragonBoss" then
            local dCfg = GameConfig.Enemies.DragonBoss
            correctedY = correctedY + (dCfg and dCfg.FlyHeight or 4.0)
        end
        e.node.position = Vector3(pos.x, correctedY, pos.z)
    end
end

--- 检测从 from 到 to 方向是否有建筑阻挡
---@param from Vector3
---@param to Vector3
---@return boolean blocked
local function isBlockedByBuilding(from, to)
    local pw = scene_:GetComponent("PhysicsWorld")
    if not pw then return false end
    local dir = to - from
    dir.y = 0
    local dist = dir:Length()
    if dist < 0.01 then return false end
    dir = dir:Normalized()
    local origin = Vector3(from.x, from.y + 0.5, from.z)  -- 腰部高度
    -- 只检测建筑层（Static）
    local result = pw:RaycastSingle(Ray(origin, dir), dist + 0.3, CollisionLayerStatic)
    return result.body ~= nil
end

local function distXZ(a, b)
    local dx, dz = a.x - b.x, a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end

local function dirXZ(from, to)
    local dx, dz = to.x - from.x, to.z - from.z
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 0.001 then return Vector3.ZERO end
    return Vector3(dx / len, 0, dz / len)
end

local function faceToward(node, target)
    local p = node.position
    node.rotation = Quaternion(math.atan(target.x - p.x, target.z - p.z) * 180 / math.pi, Vector3.UP)
end

-- ============================================================================
-- 材质缓存系统（避免每次调用创建新 Material 对象）
-- ============================================================================
local matCache_ = {}       -- color key → Material（纯色材质缓存）
local glowCache_ = {}      -- color+intensity key → Material（发光材质缓存）

--- 将颜色转为可用作 table key 的字符串
local function colorKey(c)
    return string.format("%.2f_%.2f_%.2f_%.2f", c.r, c.g, c.b, c.a)
end

local function makeMat(color)
    local key = colorKey(color)
    if not matCache_[key] then
        matCache_[key] = GameConfig.CreateMaterial(color)
    end
    return matCache_[key]
end

local function makeGlow(color, intensity)
    -- %.2f 精度：兼顾视觉平滑和缓存命中率（alpha 0→1 约 100 档 × 颜色数）
    local key = colorKey(color) .. "_" .. string.format("%.2f", intensity)
    if not glowCache_[key] then
        glowCache_[key] = GameConfig.CreateEmissiveMaterial(color, intensity)
    end
    return glowCache_[key]
end

--- 清空材质缓存（Reset 时调用，防止内存泄漏）
local function clearMatCache()
    matCache_ = {}
    glowCache_ = {}
end

-- ============================================================================
-- GetAllEnemies 帧缓存（避免每帧多次合并 table）
-- ============================================================================
local allEnemiesCache_ = nil       -- 合并后的 table
local allEnemiesCacheFrame_ = -1   -- 上次缓存的帧号

-- ============================================================================
-- 命中粒子效果（简单碎片飞散）
-- ============================================================================
local hitParticles_ = {}  -- 活跃的命中粒子列表
-- 预缓存粒子发光材质（4种颜色）
local hitParticleMats_ = nil  -- 延迟初始化

--- 在指定位置生成命中碎片粒子
local function spawnHitParticles(pos, hitDir, count)
    if not scene_ then return end
    count = count or 6
    -- 延迟初始化粒子材质缓存（只创建一次）
    if not hitParticleMats_ then
        hitParticleMats_ = {
            makeGlow(Color(1.0, 0.9, 0.3, 1.0), 2.0),  -- 金黄
            makeGlow(Color(1.0, 0.6, 0.1, 1.0), 2.0),  -- 橙色
            makeGlow(Color(1.0, 1.0, 1.0, 1.0), 2.0),  -- 白色
            makeGlow(Color(1.0, 0.3, 0.1, 1.0), 2.0),  -- 红橙
        }
    end
    for i = 1, count do
        local node = scene_:CreateChild("HitParticle")
        node.position = Vector3(
            pos.x + (math.random() - 0.5) * 0.3,
            pos.y + 0.5 + math.random() * 0.5,
            pos.z + (math.random() - 0.5) * 0.3
        )
        local s = 0.04 + math.random() * 0.06
        node.scale = Vector3(s, s, s)
        -- 随机形状（方块或球体）
        local mdl = node:CreateComponent("StaticModel")
        if math.random() > 0.5 then
            mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        else
            mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        end
        mdl:SetMaterial(hitParticleMats_[math.random(1, #hitParticleMats_)])

        -- 随机速度：主要沿击退方向 + 向上 + 随机散射
        local vx = hitDir.x * (2 + math.random() * 3) + (math.random() - 0.5) * 3
        local vy = 2 + math.random() * 4
        local vz = hitDir.z * (2 + math.random() * 3) + (math.random() - 0.5) * 3

        table.insert(hitParticles_, {
            node = node,
            vx = vx, vy = vy, vz = vz,
            life = 0.4 + math.random() * 0.3,  -- 0.4~0.7 秒
            maxLife = 0.4 + math.random() * 0.3,
            gravity = -12,
        })
    end
end

--- 更新命中粒子（在主循环中调用）
local function updateHitParticles(dt)
    local i = 1
    while i <= #hitParticles_ do
        local p = hitParticles_[i]
        p.life = p.life - dt
        if p.life <= 0 or not p.node then
            if p.node then p.node:Remove() end
            table.remove(hitParticles_, i)
        else
            -- 物理运动
            p.vy = p.vy + p.gravity * dt
            local pos = p.node.position
            p.node.position = Vector3(pos.x + p.vx * dt, pos.y + p.vy * dt, pos.z + p.vz * dt)
            -- 缩小消失
            local t = p.life / p.maxLife
            local s = (0.04 + 0.06) * t  -- 线性缩小
            p.node.scale = Vector3(s, s, s)
            -- 旋转
            p.node.rotation = p.node.rotation * Quaternion(dt * 360, Vector3(1, 1, 0):Normalized())
            i = i + 1
        end
    end
end

-- ============================================================================
-- 模型构建
-- ============================================================================

local function buildMeleeModel(root)
    local cfg = GameConfig.Enemies.Melee
    local bodyMat = makeMat(cfg.BodyColor)
    local headMat = makeMat(cfg.HeadColor)

    -- 躯干
    local body = root:CreateChild("Body")
    local bm = body:CreateComponent("StaticModel")
    bm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    bm:SetMaterial(bodyMat)
    body.scale = Vector3(0.7, 1.0, 0.5)
    body.position = Vector3(0, 0.7, 0)

    -- 胸甲板（前方突出）
    local chest = root:CreateChild("ChestPlate")
    local cpm = chest:CreateComponent("StaticModel")
    cpm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    cpm:SetMaterial(makeMat(Color(0.15, 0.15, 0.15, 1.0)))
    chest.scale = Vector3(0.6, 0.5, 0.15)
    chest.position = Vector3(0, 0.85, 0.28)

    -- 腰带
    local belt = root:CreateChild("Belt")
    local blm = belt:CreateComponent("StaticModel")
    blm:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    blm:SetMaterial(makeMat(Color(0.25, 0.12, 0.05, 1.0)))
    belt.scale = Vector3(0.38, 0.08, 0.38)
    belt.position = Vector3(0, 0.28, 0)

    -- 头
    local head = root:CreateChild("Head")
    local hm = head:CreateComponent("StaticModel")
    hm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    hm:SetMaterial(headMat)
    head.scale = Vector3(0.45, 0.45, 0.45)
    head.position = Vector3(0, 1.42, 0)

    -- 下颚
    local jaw = root:CreateChild("Jaw")
    local jm = jaw:CreateComponent("StaticModel")
    jm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    jm:SetMaterial(headMat)
    jaw.scale = Vector3(0.35, 0.12, 0.3)
    jaw.position = Vector3(0, 1.15, 0.05)

    -- 双臂（上臂+前臂）
    for _, side in ipairs({ -1, 1 }) do
        local upperArm = root:CreateChild("UpperArm")
        local uam = upperArm:CreateComponent("StaticModel")
        uam:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        uam:SetMaterial(bodyMat)
        upperArm.scale = Vector3(0.22, 0.4, 0.22)
        upperArm.position = Vector3(0.46 * side, 0.75, 0)

        local foreArm = root:CreateChild("ForeArm")
        local fam = foreArm:CreateComponent("StaticModel")
        fam:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        fam:SetMaterial(bodyMat)
        foreArm.scale = Vector3(0.18, 0.35, 0.18)
        foreArm.position = Vector3(0.46 * side, 0.35, 0.05)

        -- 拳头（球体）
        local fist = root:CreateChild("Fist")
        local fm = fist:CreateComponent("StaticModel")
        fm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        fm:SetMaterial(bodyMat)
        fist.scale = Vector3(0.14, 0.14, 0.14)
        fist.position = Vector3(0.46 * side, 0.15, 0.05)

        -- 肩甲
        local shoulder = root:CreateChild("Shoulder")
        local sm = shoulder:CreateComponent("StaticModel")
        sm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        sm:SetMaterial(makeMat(Color(0.15, 0.15, 0.15, 1.0)))
        shoulder.scale = Vector3(0.28, 0.12, 0.28)
        shoulder.position = Vector3(0.46 * side, 1.0, 0)
    end

    -- 双腿
    for _, side in ipairs({ -1, 1 }) do
        local leg = root:CreateChild("Leg")
        local lm = leg:CreateComponent("StaticModel")
        lm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        lm:SetMaterial(bodyMat)
        leg.scale = Vector3(0.22, 0.35, 0.22)
        leg.position = Vector3(0.18 * side, 0, 0)

        -- 脚
        local foot = root:CreateChild("Foot")
        local ftm = foot:CreateComponent("StaticModel")
        ftm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        ftm:SetMaterial(makeMat(Color(0.15, 0.15, 0.15, 1.0)))
        foot.scale = Vector3(0.22, 0.08, 0.3)
        foot.position = Vector3(0.18 * side, -0.18, 0.05)
    end

    -- 双眼（发光红）
    local eyeMat = makeGlow(Color(1.0, 0.2, 0.1, 1.0), 3.0)
    for _, side in ipairs({ -1, 1 }) do
        local eye = root:CreateChild("Eye")
        local em = eye:CreateComponent("StaticModel")
        em:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        em:SetMaterial(eyeMat)
        eye.scale = Vector3(0.08, 0.06, 0.05)
        eye.position = Vector3(0.12 * side, 1.48, 0.22)
    end

    -- 背部小刺（2根）
    local spikeMat = makeMat(Color(0.2, 0.05, 0.05, 1.0))
    for i = 1, 2 do
        local spike = root:CreateChild("BackSpike")
        local spm = spike:CreateComponent("StaticModel")
        spm:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        spm:SetMaterial(spikeMat)
        spike.scale = Vector3(0.06, 0.2, 0.06)
        spike.position = Vector3((i - 1.5) * 0.2, 1.0, -0.28)
    end
end

local function buildRangedModel(root)
    local cfg = GameConfig.Enemies.Ranged
    local bodyMat = makeMat(cfg.BodyColor)
    local glowMat = makeGlow(cfg.HeadColor, 2.5)

    -- 身体（圆柱，分上下两段增加细节）
    local body = root:CreateChild("Body")
    local bm = body:CreateComponent("StaticModel")
    bm:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    bm:SetMaterial(bodyMat)
    body.scale = Vector3(0.4, 0.7, 0.4)
    body.position = Vector3(0, 0.35, 0)

    -- 上身（略宽）
    local upper = root:CreateChild("UpperBody")
    local ubm = upper:CreateComponent("StaticModel")
    ubm:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    ubm:SetMaterial(bodyMat)
    upper.scale = Vector3(0.45, 0.4, 0.45)
    upper.position = Vector3(0, 0.85, 0)

    -- 领圈（发光环）
    local collar = root:CreateChild("Collar")
    local clm = collar:CreateComponent("StaticModel")
    clm:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
    clm:SetMaterial(glowMat)
    collar.scale = Vector3(0.25, 0.25, 0.25)
    collar.position = Vector3(0, 1.05, 0)

    -- 头（发光球）
    local head = root:CreateChild("Head")
    local hm = head:CreateComponent("StaticModel")
    hm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    hm:SetMaterial(glowMat)
    head.scale = Vector3(0.4, 0.4, 0.4)
    head.position = Vector3(0, 1.3, 0)

    -- 双眼（小亮点）
    local eyeMat = makeGlow(Color(1.0, 1.0, 0.5, 1.0), 4.0)
    for _, side in ipairs({ -1, 1 }) do
        local eye = root:CreateChild("Eye")
        local em = eye:CreateComponent("StaticModel")
        em:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        em:SetMaterial(eyeMat)
        eye.scale = Vector3(0.06, 0.05, 0.04)
        eye.position = Vector3(0.1 * side, 1.35, 0.18)
    end

    -- 光环
    local light = head:CreateComponent("Light")
    light.lightType = LIGHT_POINT
    light.castShadows = false
    light.range = 4.0
    light.color = Color(0.2, 0.8, 0.4, 1.0)
    light.brightness = 0.8

    -- 旋转环（中腰）
    local ring = root:CreateChild("Ring")
    local rm = ring:CreateComponent("StaticModel")
    rm:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
    rm:SetMaterial(makeGlow(cfg.HeadColor, 1.5))
    ring.scale = Vector3(0.35, 0.35, 0.35)
    ring.position = Vector3(0, 0.7, 0)

    -- 浮游球（双侧各一）
    for _, side in ipairs({ -1, 1 }) do
        local orb = root:CreateChild("Orb")
        local om = orb:CreateComponent("StaticModel")
        om:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        om:SetMaterial(glowMat)
        orb.scale = Vector3(0.12, 0.12, 0.12)
        orb.position = Vector3(0.5 * side, 0.9, 0)
    end

    -- 底部能量锥（倒锥，暗示悬浮）
    local baseCone = root:CreateChild("BaseCone")
    local bcm = baseCone:CreateComponent("StaticModel")
    bcm:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
    bcm:SetMaterial(makeGlow(cfg.HeadColor, 1.0))
    baseCone.scale = Vector3(0.2, 0.25, 0.2)
    baseCone.position = Vector3(0, -0.05, 0)
    baseCone.rotation = Quaternion(180, Vector3.FORWARD)
end

local function buildBossModel(root)
    local cfg = GameConfig.Enemies.Boss
    local s = cfg.Scale
    local bodyMat = makeMat(cfg.BodyColor)
    local headMat = makeMat(cfg.HeadColor)
    local armorMat = makeMat(Color(0.2, 0.08, 0.08, 1.0))

    -- 身体（大型）
    local body = root:CreateChild("Body")
    local bm = body:CreateComponent("StaticModel")
    bm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    bm:SetMaterial(bodyMat)
    body.scale = Vector3(0.9 * s, 1.3 * s, 0.6 * s)
    body.position = Vector3(0, 0.8 * s, 0)

    -- 胸甲
    local chest = root:CreateChild("ChestArmor")
    local cm = chest:CreateComponent("StaticModel")
    cm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    cm:SetMaterial(armorMat)
    chest.scale = Vector3(0.8 * s, 0.6 * s, 0.2 * s)
    chest.position = Vector3(0, 1.05 * s, 0.32 * s)

    -- 腰甲
    local waist = root:CreateChild("WaistArmor")
    local wm = waist:CreateComponent("StaticModel")
    wm:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    wm:SetMaterial(armorMat)
    waist.scale = Vector3(0.5 * s, 0.1 * s, 0.5 * s)
    waist.position = Vector3(0, 0.22 * s, 0)

    -- 头
    local head = root:CreateChild("Head")
    local hm = head:CreateComponent("StaticModel")
    hm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    hm:SetMaterial(headMat)
    head.scale = Vector3(0.55 * s, 0.55 * s, 0.55 * s)
    head.position = Vector3(0, 1.75 * s, 0)

    -- 下颚
    local jaw = root:CreateChild("Jaw")
    local jm = jaw:CreateComponent("StaticModel")
    jm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    jm:SetMaterial(headMat)
    jaw.scale = Vector3(0.4 * s, 0.15 * s, 0.35 * s)
    jaw.position = Vector3(0, 1.44 * s, 0.05 * s)

    -- 双角（Boss 标志）
    local hornMat = makeGlow(Color(1.0, 0.3, 0.0, 1.0), 3.0)
    for _, side in ipairs({ -1, 1 }) do
        local horn = root:CreateChild("Horn")
        local hom = horn:CreateComponent("StaticModel")
        hom:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        hom:SetMaterial(hornMat)
        horn.scale = Vector3(0.12 * s, 0.4 * s, 0.12 * s)
        horn.position = Vector3(0.2 * side * s, 2.05 * s, 0)
    end

    -- 双臂（上臂+前臂+拳头）
    for _, side in ipairs({ -1, 1 }) do
        local upperArm = root:CreateChild("UpperArm")
        local uam = upperArm:CreateComponent("StaticModel")
        uam:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        uam:SetMaterial(bodyMat)
        upperArm.scale = Vector3(0.3 * s, 0.5 * s, 0.3 * s)
        upperArm.position = Vector3(0.6 * side * s, 0.85 * s, 0)

        local foreArm = root:CreateChild("ForeArm")
        local fam = foreArm:CreateComponent("StaticModel")
        fam:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        fam:SetMaterial(bodyMat)
        foreArm.scale = Vector3(0.25 * s, 0.45 * s, 0.25 * s)
        foreArm.position = Vector3(0.6 * side * s, 0.35 * s, 0.05 * s)

        local fist = root:CreateChild("Fist")
        local fm = fist:CreateComponent("StaticModel")
        fm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        fm:SetMaterial(bodyMat)
        fist.scale = Vector3(0.2 * s, 0.2 * s, 0.2 * s)
        fist.position = Vector3(0.6 * side * s, 0.1 * s, 0.05 * s)

        -- 肩甲
        local shoulder = root:CreateChild("ShoulderGuard")
        local sgm = shoulder:CreateComponent("StaticModel")
        sgm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        sgm:SetMaterial(armorMat)
        shoulder.scale = Vector3(0.38 * s, 0.15 * s, 0.38 * s)
        shoulder.position = Vector3(0.6 * side * s, 1.15 * s, 0)
    end

    -- 双腿
    for _, side in ipairs({ -1, 1 }) do
        local leg = root:CreateChild("Leg")
        local lm = leg:CreateComponent("StaticModel")
        lm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        lm:SetMaterial(bodyMat)
        leg.scale = Vector3(0.28 * s, 0.4 * s, 0.28 * s)
        leg.position = Vector3(0.25 * side * s, -0.05 * s, 0)

        local foot = root:CreateChild("Foot")
        local ftm = foot:CreateComponent("StaticModel")
        ftm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        ftm:SetMaterial(armorMat)
        foot.scale = Vector3(0.3 * s, 0.1 * s, 0.38 * s)
        foot.position = Vector3(0.25 * side * s, -0.28 * s, 0.05 * s)
    end

    -- 双眼（亮红发光）
    local eyeMat = makeGlow(Color(1.0, 0.1, 0.0, 1.0), 5.0)
    for _, side in ipairs({ -1, 1 }) do
        local eye = root:CreateChild("Eye")
        local em = eye:CreateComponent("StaticModel")
        em:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        em:SetMaterial(eyeMat)
        eye.scale = Vector3(0.1 * s, 0.08 * s, 0.06 * s)
        eye.position = Vector3(0.14 * side * s, 1.82 * s, 0.27 * s)
    end

    -- 背部尖刺（3根）
    local spikeMat = makeGlow(Color(0.8, 0.15, 0.0, 1.0), 2.0)
    for i = 1, 3 do
        local spike = root:CreateChild("BackSpike")
        local spm = spike:CreateComponent("StaticModel")
        spm:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        spm:SetMaterial(spikeMat)
        spike.scale = Vector3(0.08 * s, (0.25 + i * 0.05) * s, 0.08 * s)
        spike.position = Vector3((i - 2) * 0.2 * s, 1.1 * s, -0.35 * s)
    end

    -- 光环
    local light = head:CreateComponent("Light")
    light.lightType = LIGHT_POINT
    light.castShadows = false
    light.range = 8.0
    light.color = Color(1.0, 0.3, 0.1, 1.0)
    light.brightness = 1.5
end

-- ============================================================================
-- 龙Boss模型构建（黑暗中国龙）
-- ============================================================================

local function buildDragonBossModel(root, level)
    local cfg = GameConfig.Enemies.DragonBoss
    local sc = GameConfig.Enemies.LevelScaling
    local s = cfg.Scale + (level - 1) * 0.1  -- 每10级略微增大

    local bodyMat = makeMat(cfg.BodyColor)
    local scaleMat = makeMat(cfg.ScaleColor)
    local hornMat = makeGlow(cfg.HornColor, 3.0)
    local eyeMat = makeGlow(cfg.EyeColor, 5.0)
    local glowMat = makeGlow(cfg.GlowColor, 2.5)

    -- ===== 龙头 =====
    local head = root:CreateChild("Head")
    local hm = head:CreateComponent("StaticModel")
    hm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    hm:SetMaterial(bodyMat)
    head.scale = Vector3(0.5 * s, 0.35 * s, 0.7 * s)
    head.position = Vector3(0, 0, 1.8 * s)

    -- 龙嘴（下颚）
    local jaw = head:CreateChild("Jaw")
    local jm = jaw:CreateComponent("StaticModel")
    jm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    jm:SetMaterial(scaleMat)
    jaw.scale = Vector3(0.8, 0.3, 0.6)
    jaw.position = Vector3(0, -0.3, 0.2)

    -- 双眼
    for _, side in ipairs({ -1, 1 }) do
        local eye = head:CreateChild("Eye")
        local em = eye:CreateComponent("StaticModel")
        em:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        em:SetMaterial(eyeMat)
        eye.scale = Vector3(0.15, 0.12, 0.12)
        eye.position = Vector3(0.18 * side, 0.1, 0.25)
    end

    -- 双角（鹿角风格，向后弯曲）
    for _, side in ipairs({ -1, 1 }) do
        local horn = head:CreateChild("Horn")
        local hom = horn:CreateComponent("StaticModel")
        hom:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        hom:SetMaterial(hornMat)
        horn.scale = Vector3(0.08 * s, 0.5 * s, 0.08 * s)
        horn.position = Vector3(0.15 * side * s, 0.25 * s, -0.1 * s)
        horn.rotation = Quaternion(-30, Vector3(side, 0, 1))

        -- 角分叉
        local branch = horn:CreateChild("Branch")
        local bm = branch:CreateComponent("StaticModel")
        bm:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        bm:SetMaterial(hornMat)
        branch.scale = Vector3(0.6, 0.5, 0.6)
        branch.position = Vector3(0.15 * side, 0.35, 0)
        branch.rotation = Quaternion(40 * side, Vector3.FORWARD)
    end

    -- 龙须（每侧两根）
    for _, side in ipairs({ -1, 1 }) do
        for j = 1, 2 do
            local whisker = head:CreateChild("Whisker")
            local wm = whisker:CreateComponent("StaticModel")
            wm:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
            wm:SetMaterial(glowMat)
            whisker.scale = Vector3(0.02 * s, 0.4 * s, 0.02 * s)
            whisker.position = Vector3(0.22 * side * s, -0.05 * s, 0.3 * s + (j - 1) * 0.08 * s)
            whisker.rotation = Quaternion(70 * side + (j - 1) * 15, Vector3.FORWARD)
        end
    end

    -- ===== 蛇形龙身（5段连续体节）=====
    local segCount = 5
    for i = 1, segCount do
        local seg = root:CreateChild("BodySeg" .. i)
        local sm = seg:CreateComponent("StaticModel")
        sm:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        -- 交替使用身体色和鳞片色
        sm:SetMaterial((i % 2 == 1) and bodyMat or scaleMat)
        local segScale = (1.0 - (i - 1) * 0.12) * s  -- 逐渐变细
        seg.scale = Vector3(0.3 * segScale, 0.25 * s, 0.3 * segScale)
        seg.position = Vector3(0, 0, (1.8 - i * 0.55) * s)
        seg.rotation = Quaternion(90, Vector3.RIGHT)  -- 横放圆柱作为身体段

        -- 背脊（每段一个小锥体）
        local spine = seg:CreateChild("Spine")
        local spm = spine:CreateComponent("StaticModel")
        spm:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        spm:SetMaterial(hornMat)
        spine.scale = Vector3(0.3, 0.5, 0.3)
        spine.position = Vector3(0, 0.5, 0)
    end

    -- ===== 龙尾 =====
    local tail = root:CreateChild("Tail")
    local tm = tail:CreateComponent("StaticModel")
    tm:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
    tm:SetMaterial(scaleMat)
    tail.scale = Vector3(0.15 * s, 0.6 * s, 0.15 * s)
    tail.position = Vector3(0, 0, -1.2 * s)
    tail.rotation = Quaternion(90, Vector3.RIGHT)

    -- 尾尖发光
    local tailTip = tail:CreateChild("TailTip")
    local ttm = tailTip:CreateComponent("StaticModel")
    ttm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    ttm:SetMaterial(glowMat)
    tailTip.scale = Vector3(0.5, 0.5, 0.5)
    tailTip.position = Vector3(0, 0.5, 0)

    -- ===== 四爪 =====
    local clawPositions = {
        { x = 0.4, z = 1.0 },   -- 前左
        { x = -0.4, z = 1.0 },  -- 前右
        { x = 0.35, z = -0.3 },  -- 后左
        { x = -0.35, z = -0.3 }, -- 后右
    }
    for _, cp in ipairs(clawPositions) do
        local claw = root:CreateChild("Claw")
        local cm = claw:CreateComponent("StaticModel")
        cm:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        cm:SetMaterial(scaleMat)
        claw.scale = Vector3(0.08 * s, 0.25 * s, 0.08 * s)
        claw.position = Vector3(cp.x * s, -0.25 * s, cp.z * s)
        claw.rotation = Quaternion(180, Vector3.FORWARD)  -- 爪朝下
    end

    -- ===== 龙身环绕光环 =====
    local auraRing = root:CreateChild("AuraRing")
    local arm = auraRing:CreateComponent("StaticModel")
    arm:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
    arm:SetMaterial(glowMat)
    auraRing.scale = Vector3(0.8 * s, 0.8 * s, 0.8 * s)
    auraRing.position = Vector3(0, 0, 0.5 * s)

    -- ===== 点光源 =====
    local light = root:CreateComponent("Light")
    light.lightType = LIGHT_POINT
    light.castShadows = false
    light.range = 12.0 + level * 2
    light.color = Color(0.6, 0.1, 0.8, 1.0)
    light.brightness = 2.0 + level * 0.2
end

-- ============================================================================
-- 终极Boss模型构建（深渊魔王）
-- ============================================================================

local function buildUltimateBossModel(root, level)
    local cfg = GameConfig.Enemies.UltimateBoss
    local s = cfg.Scale + (level - 1) * 0.05

    local bodyMat = makeMat(cfg.BodyColor)
    local armorMat = makeMat(cfg.ArmorColor)
    local hornMat = makeGlow(cfg.HornColor, 4.0)
    local eyeMat = makeGlow(cfg.EyeColor, 6.0)
    local glowMat = makeGlow(cfg.GlowColor, 3.0)
    local auraMat = makeGlow(cfg.AuraColor, 2.0)

    -- ===== 身体（巨大躯干）=====
    local body = root:CreateChild("Body")
    local bm = body:CreateComponent("StaticModel")
    bm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    bm:SetMaterial(bodyMat)
    body.scale = Vector3(1.2 * s, 2.0 * s, 0.8 * s)
    body.position = Vector3(0, 1.0 * s, 0)

    -- ===== 铠甲胸板 =====
    local chest = root:CreateChild("ChestArmor")
    local cm = chest:CreateComponent("StaticModel")
    cm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    cm:SetMaterial(armorMat)
    chest.scale = Vector3(1.1 * s, 1.0 * s, 0.3 * s)
    chest.position = Vector3(0, 1.3 * s, 0.3 * s)

    -- ===== 头部 =====
    local head = root:CreateChild("Head")
    local hm = head:CreateComponent("StaticModel")
    hm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    hm:SetMaterial(bodyMat)
    head.scale = Vector3(0.7 * s, 0.7 * s, 0.7 * s)
    head.position = Vector3(0, 2.35 * s, 0)

    -- ===== 角冠（6只角环绕头顶）=====
    local hornCount = math.min(3 + math.floor(level / 2), 6)
    for i = 1, hornCount do
        local angle = (i - 1) * (6.28 / hornCount)
        local hx = math.sin(angle) * 0.3 * s
        local hz = math.cos(angle) * 0.3 * s
        local horn = root:CreateChild("Horn" .. i)
        local hom = horn:CreateComponent("StaticModel")
        hom:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        hom:SetMaterial(hornMat)
        horn.scale = Vector3(0.1 * s, (0.5 + i * 0.05) * s, 0.1 * s)
        horn.position = Vector3(hx, 2.75 * s, hz)
        horn.rotation = Quaternion(math.sin(angle) * 20, Vector3.FORWARD) *
                         Quaternion(math.cos(angle) * 20, Vector3.RIGHT)
    end

    -- ===== 双眼（金色魔眼）=====
    for _, side in ipairs({ -1, 1 }) do
        local eye = root:CreateChild("Eye")
        local em = eye:CreateComponent("StaticModel")
        em:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        em:SetMaterial(eyeMat)
        eye.scale = Vector3(0.12 * s, 0.10 * s, 0.08 * s)
        eye.position = Vector3(0.18 * side * s, 2.45 * s, 0.34 * s)
    end

    -- ===== 四臂（上臂更粗壮，下臂较细）=====
    for _, side in ipairs({ -1, 1 }) do
        -- 上臂（主臂）
        local upperArm = root:CreateChild("UpperArm")
        local uam = upperArm:CreateComponent("StaticModel")
        uam:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        uam:SetMaterial(bodyMat)
        upperArm.scale = Vector3(0.35 * s, 1.2 * s, 0.35 * s)
        upperArm.position = Vector3(0.78 * side * s, 1.2 * s, 0)

        -- 上臂护甲
        local armGuard = upperArm:CreateChild("ArmGuard")
        local agm = armGuard:CreateComponent("StaticModel")
        agm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        agm:SetMaterial(armorMat)
        armGuard.scale = Vector3(1.2, 0.4, 1.2)
        armGuard.position = Vector3(0, 0.3, 0)

        -- 下臂（副臂，略低略小）
        local lowerArm = root:CreateChild("LowerArm")
        local lam = lowerArm:CreateComponent("StaticModel")
        lam:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        lam:SetMaterial(bodyMat)
        lowerArm.scale = Vector3(0.25 * s, 0.9 * s, 0.25 * s)
        lowerArm.position = Vector3(0.65 * side * s, 0.4 * s, 0.15 * s)
    end

    -- ===== 腿部 =====
    for _, side in ipairs({ -1, 1 }) do
        local leg = root:CreateChild("Leg")
        local lm = leg:CreateComponent("StaticModel")
        lm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        lm:SetMaterial(bodyMat)
        leg.scale = Vector3(0.35 * s, 0.8 * s, 0.35 * s)
        leg.position = Vector3(0.35 * side * s, -0.4 * s, 0)
    end

    -- ===== 血红光环（脚下旋转环）=====
    local auraRing = root:CreateChild("AuraRing")
    local arm = auraRing:CreateComponent("StaticModel")
    arm:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
    arm:SetMaterial(auraMat)
    auraRing.scale = Vector3(1.2 * s, 1.2 * s, 1.2 * s)
    auraRing.position = Vector3(0, 0.1, 0)

    -- ===== 背部烈焰光环 =====
    local backAura = root:CreateChild("BackAura")
    local bam = backAura:CreateComponent("StaticModel")
    bam:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
    bam:SetMaterial(glowMat)
    backAura.scale = Vector3(0.8 * s, 0.8 * s, 0.8 * s)
    backAura.position = Vector3(0, 1.5 * s, -0.3 * s)
    backAura.rotation = Quaternion(90, Vector3.RIGHT)

    -- ===== 点光源（深渊之光）=====
    local light = root:CreateComponent("Light")
    light.lightType = LIGHT_POINT
    light.castShadows = false
    light.range = 15.0 + level * 2
    light.color = Color(1.0, 0.15, 0.0, 1.0)
    light.brightness = 3.0

    -- 第二光源（血红脚下光）
    local light2 = root:CreateChild("BottomLight")
    local bl = light2:CreateComponent("Light")
    bl.lightType = LIGHT_POINT
    bl.castShadows = false
    bl.range = 10.0
    bl.color = cfg.AuraColor
    bl.brightness = 2.0
    light2.position = Vector3(0, 0.2, 0)
end

-- ============================================================================
-- 精英怪模型构建
-- ============================================================================

local function buildEliteMeleeModel(root)
    local cfg = GameConfig.Enemies.EliteMelee
    local bodyMat = makeMat(cfg.BodyColor)
    local headMat = makeMat(cfg.HeadColor)
    local armorMat = makeMat(Color(0.18, 0.08, 0.02, 1.0))

    -- 身体（比普通近战大一圈）
    local body = root:CreateChild("Body")
    local bm = body:CreateComponent("StaticModel")
    bm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    bm:SetMaterial(bodyMat)
    body.scale = Vector3(0.85, 1.2, 0.6)
    body.position = Vector3(0, 0.75, 0)

    -- 胸甲板
    local chest = root:CreateChild("ChestPlate")
    local cpm = chest:CreateComponent("StaticModel")
    cpm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    cpm:SetMaterial(armorMat)
    chest.scale = Vector3(0.75, 0.6, 0.18)
    chest.position = Vector3(0, 0.95, 0.32)

    -- 腰带
    local belt = root:CreateChild("Belt")
    local blm = belt:CreateComponent("StaticModel")
    blm:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    blm:SetMaterial(armorMat)
    belt.scale = Vector3(0.46, 0.08, 0.46)
    belt.position = Vector3(0, 0.22, 0)

    -- 头
    local head = root:CreateChild("Head")
    local hm = head:CreateComponent("StaticModel")
    hm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    hm:SetMaterial(headMat)
    head.scale = Vector3(0.5, 0.5, 0.5)
    head.position = Vector3(0, 1.65, 0)

    -- 下颚
    local jaw = root:CreateChild("Jaw")
    local jm = jaw:CreateComponent("StaticModel")
    jm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    jm:SetMaterial(headMat)
    jaw.scale = Vector3(0.4, 0.12, 0.35)
    jaw.position = Vector3(0, 1.36, 0.05)

    -- 双臂（上臂+前臂+护手）
    for _, side in ipairs({ -1, 1 }) do
        local upperArm = root:CreateChild("UpperArm")
        local uam = upperArm:CreateComponent("StaticModel")
        uam:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        uam:SetMaterial(bodyMat)
        upperArm.scale = Vector3(0.28, 0.45, 0.28)
        upperArm.position = Vector3(0.56 * side, 0.82, 0)

        local foreArm = root:CreateChild("ForeArm")
        local fam = foreArm:CreateComponent("StaticModel")
        fam:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        fam:SetMaterial(bodyMat)
        foreArm.scale = Vector3(0.22, 0.4, 0.22)
        foreArm.position = Vector3(0.56 * side, 0.38, 0.05)

        -- 护手（发光）
        local gauntlet = root:CreateChild("Gauntlet")
        local gm = gauntlet:CreateComponent("StaticModel")
        gm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        gm:SetMaterial(makeGlow(Color(0.9, 0.3, 0.1, 1.0), 2.0))
        gauntlet.scale = Vector3(0.18, 0.18, 0.18)
        gauntlet.position = Vector3(0.56 * side, 0.15, 0.05)

        -- 肩刺
        local shoulderSpike = root:CreateChild("ShoulderSpike")
        local ssm = shoulderSpike:CreateComponent("StaticModel")
        ssm:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        ssm:SetMaterial(armorMat)
        shoulderSpike.scale = Vector3(0.1, 0.2, 0.1)
        shoulderSpike.position = Vector3(0.6 * side, 1.1, 0)
    end

    -- 双腿
    for _, side in ipairs({ -1, 1 }) do
        local leg = root:CreateChild("Leg")
        local lm = leg:CreateComponent("StaticModel")
        lm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        lm:SetMaterial(bodyMat)
        leg.scale = Vector3(0.25, 0.4, 0.25)
        leg.position = Vector3(0.2 * side, 0, 0)

        local foot = root:CreateChild("Foot")
        local ftm = foot:CreateComponent("StaticModel")
        ftm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        ftm:SetMaterial(armorMat)
        foot.scale = Vector3(0.26, 0.1, 0.35)
        foot.position = Vector3(0.2 * side, -0.22, 0.05)
    end

    -- 双眼（亮红发光）
    local eyeMat = makeGlow(Color(1.0, 0.1, 0.0, 1.0), 4.0)
    for _, side in ipairs({ -1, 1 }) do
        local eye = root:CreateChild("Eye")
        local em = eye:CreateComponent("StaticModel")
        em:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        em:SetMaterial(eyeMat)
        eye.scale = Vector3(0.09, 0.07, 0.06)
        eye.position = Vector3(0.14 * side, 1.72, 0.24)
    end

    -- 头顶双角（精英标志，比普通多一根）
    local hornMat = makeGlow(Color(1.0, 0.4, 0.1, 1.0), 2.5)
    for _, side in ipairs({ -1, 1 }) do
        local horn = root:CreateChild("Horn")
        local hom = horn:CreateComponent("StaticModel")
        hom:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        hom:SetMaterial(hornMat)
        horn.scale = Vector3(0.08, 0.22, 0.08)
        horn.position = Vector3(0.12 * side, 1.95, 0)
    end

    -- 背部尖刺（3根，精英标志）
    for i = 1, 3 do
        local spike = root:CreateChild("BackSpike")
        local spm = spike:CreateComponent("StaticModel")
        spm:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        spm:SetMaterial(makeGlow(Color(0.7, 0.2, 0.05, 1.0), 1.5))
        spike.scale = Vector3(0.06, 0.18 + i * 0.03, 0.06)
        spike.position = Vector3((i - 2) * 0.18, 1.05, -0.35)
    end
end

local function buildEliteRangedModel(root)
    local cfg = GameConfig.Enemies.EliteRanged
    local bodyMat = makeMat(cfg.BodyColor)
    local glowMat = makeGlow(cfg.HeadColor, 3.0)

    -- 身体下段（圆柱）
    local body = root:CreateChild("Body")
    local bm = body:CreateComponent("StaticModel")
    bm:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    bm:SetMaterial(bodyMat)
    body.scale = Vector3(0.5, 0.8, 0.5)
    body.position = Vector3(0, 0.4, 0)

    -- 身体上段（略宽）
    local upper = root:CreateChild("UpperBody")
    local ubm = upper:CreateComponent("StaticModel")
    ubm:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    ubm:SetMaterial(bodyMat)
    upper.scale = Vector3(0.55, 0.45, 0.55)
    upper.position = Vector3(0, 1.0, 0)

    -- 领圈（发光）
    local collar = root:CreateChild("Collar")
    local clm = collar:CreateComponent("StaticModel")
    clm:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
    clm:SetMaterial(glowMat)
    collar.scale = Vector3(0.3, 0.3, 0.3)
    collar.position = Vector3(0, 1.25, 0)

    -- 头（发光球）
    local head = root:CreateChild("Head")
    local hm = head:CreateComponent("StaticModel")
    hm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    hm:SetMaterial(glowMat)
    head.scale = Vector3(0.5, 0.5, 0.5)
    head.position = Vector3(0, 1.55, 0)

    -- 头顶水晶（精英标志）
    local crystal = root:CreateChild("Crystal")
    local crm = crystal:CreateComponent("StaticModel")
    crm:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
    crm:SetMaterial(makeGlow(Color(0.8, 0.3, 1.0, 1.0), 4.0))
    crystal.scale = Vector3(0.1, 0.25, 0.1)
    crystal.position = Vector3(0, 1.9, 0)

    -- 双眼
    local eyeMat = makeGlow(Color(1.0, 0.8, 0.3, 1.0), 5.0)
    for _, side in ipairs({ -1, 1 }) do
        local eye = root:CreateChild("Eye")
        local em = eye:CreateComponent("StaticModel")
        em:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        em:SetMaterial(eyeMat)
        eye.scale = Vector3(0.07, 0.06, 0.05)
        eye.position = Vector3(0.12 * side, 1.6, 0.22)
    end

    -- 光环
    local light = head:CreateComponent("Light")
    light.lightType = LIGHT_POINT
    light.castShadows = false
    light.range = 5.0
    light.color = Color(0.5, 0.2, 1.0, 1.0)
    light.brightness = 1.2

    -- 双旋转环（精英标志）
    for i, y in ipairs({ 0.5, 0.9 }) do
        local ring = root:CreateChild("Ring" .. i)
        local rm = ring:CreateComponent("StaticModel")
        rm:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
        rm:SetMaterial(makeGlow(cfg.HeadColor, 2.0))
        ring.scale = Vector3(0.4, 0.4, 0.4)
        ring.position = Vector3(0, y, 0)
    end

    -- 浮游球（3个环绕）
    for i = 1, 3 do
        local a = (i - 1) * 2.094
        local orb = root:CreateChild("Orb" .. i)
        local om = orb:CreateComponent("StaticModel")
        om:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        om:SetMaterial(glowMat)
        orb.scale = Vector3(0.1, 0.1, 0.1)
        orb.position = Vector3(math.sin(a) * 0.55, 1.1, math.cos(a) * 0.55)
    end

    -- 底部倒锥（悬浮暗示）
    local baseCone = root:CreateChild("BaseCone")
    local bcm = baseCone:CreateComponent("StaticModel")
    bcm:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
    bcm:SetMaterial(makeGlow(cfg.HeadColor, 1.2))
    baseCone.scale = Vector3(0.25, 0.3, 0.25)
    baseCone.position = Vector3(0, -0.05, 0)
    baseCone.rotation = Quaternion(180, Vector3.FORWARD)
end

-- ============================================================================
-- 炼狱术士模型（精英AOE）
-- ============================================================================

local function buildEliteAOEModel(root)
    local cfg = GameConfig.Enemies.EliteAOE
    local bodyMat = makeMat(cfg.BodyColor)
    local headMat = makeGlow(cfg.HeadColor, 3.0)
    local glowMat = makeGlow(cfg.GlowColor, 2.5)

    -- 身体下段（圆柱，橙红色）
    local body = root:CreateChild("Body")
    local bm = body:CreateComponent("StaticModel")
    bm:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    bm:SetMaterial(bodyMat)
    body.scale = Vector3(0.55, 0.9, 0.55)
    body.position = Vector3(0, 0.45, 0)

    -- 身体上段（胸腔，略窄）
    local upper = root:CreateChild("UpperBody")
    local ubm = upper:CreateComponent("StaticModel")
    ubm:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    ubm:SetMaterial(bodyMat)
    upper.scale = Vector3(0.5, 0.45, 0.5)
    upper.position = Vector3(0, 1.1, 0)

    -- 胸口熔岩核心（发光球）
    local core = root:CreateChild("Core")
    local crm = core:CreateComponent("StaticModel")
    crm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    crm:SetMaterial(glowMat)
    core.scale = Vector3(0.18, 0.18, 0.18)
    core.position = Vector3(0, 1.0, 0.28)

    -- 头（发光球，亮橙）
    local head = root:CreateChild("Head")
    local hm = head:CreateComponent("StaticModel")
    hm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    hm:SetMaterial(headMat)
    head.scale = Vector3(0.5, 0.5, 0.5)
    head.position = Vector3(0, 1.55, 0)

    -- 头顶火焰锥（三叉火焰冠）
    for i = -1, 1 do
        local flameCone = root:CreateChild("FlameCone")
        local fcm = flameCone:CreateComponent("StaticModel")
        fcm:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        fcm:SetMaterial(glowMat)
        flameCone.scale = Vector3(0.1, 0.25 + math.abs(i) * (-0.05), 0.1)
        flameCone.position = Vector3(i * 0.12, 1.9, 0)
    end

    -- 双臂（上臂+前臂，张开）
    for _, side in ipairs({ -1, 1 }) do
        local upperArm = root:CreateChild("UpperArm")
        local uam = upperArm:CreateComponent("StaticModel")
        uam:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        uam:SetMaterial(bodyMat)
        upperArm.scale = Vector3(0.22, 0.38, 0.22)
        upperArm.position = Vector3(0.48 * side, 1.05, 0)
        upperArm.rotation = Quaternion(20 * side, Vector3.FORWARD)

        local foreArm = root:CreateChild("ForeArm")
        local fam = foreArm:CreateComponent("StaticModel")
        fam:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        fam:SetMaterial(bodyMat)
        foreArm.scale = Vector3(0.18, 0.35, 0.18)
        foreArm.position = Vector3(0.6 * side, 0.7, 0)
        foreArm.rotation = Quaternion(25 * side, Vector3.FORWARD)

        -- 手部火球
        local handFire = root:CreateChild("HandFire")
        local hfm = handFire:CreateComponent("StaticModel")
        hfm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        hfm:SetMaterial(glowMat)
        handFire.scale = Vector3(0.14, 0.14, 0.14)
        handFire.position = Vector3(0.7 * side, 0.48, 0)
    end

    -- 脚下火焰环（双层Torus）
    local ring = root:CreateChild("FireRing")
    local rm = ring:CreateComponent("StaticModel")
    rm:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
    rm:SetMaterial(glowMat)
    ring.scale = Vector3(0.6, 0.6, 0.6)
    ring.position = Vector3(0, 0.05, 0)

    local ring2 = root:CreateChild("FireRing2")
    local rm2 = ring2:CreateComponent("StaticModel")
    rm2:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
    rm2:SetMaterial(makeGlow(cfg.GlowColor, 1.5))
    ring2.scale = Vector3(0.45, 0.45, 0.45)
    ring2.position = Vector3(0, 0.15, 0)
    ring2.rotation = Quaternion(45, Vector3.UP)

    -- 双眼（亮黄发光）
    local eyeMat = makeGlow(Color(1.0, 0.9, 0.1, 1.0), 4.0)
    for _, side in ipairs({ -1, 1 }) do
        local eye = root:CreateChild("Eye")
        local em = eye:CreateComponent("StaticModel")
        em:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        em:SetMaterial(eyeMat)
        eye.scale = Vector3(0.08, 0.06, 0.06)
        eye.position = Vector3(0.12 * side, 1.6, 0.22)
    end

    -- 背部火焰尖刺（4根）
    for i = 1, 4 do
        local spike = root:CreateChild("FireSpike")
        local spm = spike:CreateComponent("StaticModel")
        spm:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        spm:SetMaterial(glowMat)
        spike.scale = Vector3(0.06, 0.15 + i * 0.04, 0.06)
        spike.position = Vector3((i - 2.5) * 0.14, 1.0, -0.32)
    end

    -- 橙色点光源
    local light = head:CreateComponent("Light")
    light.lightType = LIGHT_POINT
    light.castShadows = false
    light.range = 6.0
    light.color = Color(1.0, 0.5, 0.1, 1.0)
    light.brightness = 1.5
end

-- ============================================================================
-- 瘟疫幽魂模型（精英Debuff）
-- ============================================================================

local function buildEliteDebuffModel(root)
    local cfg = GameConfig.Enemies.EliteDebuff
    local bodyMat = makeMat(cfg.BodyColor)
    local headMat = makeGlow(cfg.HeadColor, 3.0)
    local glowMat = makeGlow(cfg.GlowColor, 2.0)

    -- 身体下段（圆柱，暗绿）
    local body = root:CreateChild("Body")
    local bm = body:CreateComponent("StaticModel")
    bm:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    bm:SetMaterial(bodyMat)
    body.scale = Vector3(0.45, 0.7, 0.45)
    body.position = Vector3(0, 0.35, 0)

    -- 身体上段
    local upper = root:CreateChild("UpperBody")
    local ubm = upper:CreateComponent("StaticModel")
    ubm:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    ubm:SetMaterial(bodyMat)
    upper.scale = Vector3(0.5, 0.45, 0.5)
    upper.position = Vector3(0, 0.9, 0)

    -- 瘟疫核心（胸口发光球）
    local core = root:CreateChild("PlagueCore")
    local crm = core:CreateComponent("StaticModel")
    crm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    crm:SetMaterial(glowMat)
    core.scale = Vector3(0.15, 0.15, 0.15)
    core.position = Vector3(0, 0.85, 0.26)

    -- 头（发光球，毒绿）
    local head = root:CreateChild("Head")
    local hm = head:CreateComponent("StaticModel")
    hm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    hm:SetMaterial(headMat)
    head.scale = Vector3(0.45, 0.45, 0.45)
    head.position = Vector3(0, 1.35, 0)

    -- 头顶毒角（双角）
    local hornMat = makeGlow(Color(0.3, 0.8, 0.1, 1.0), 3.0)
    for _, side in ipairs({ -1, 1 }) do
        local horn = root:CreateChild("PoisonHorn")
        local hom = horn:CreateComponent("StaticModel")
        hom:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        hom:SetMaterial(hornMat)
        horn.scale = Vector3(0.06, 0.18, 0.06)
        horn.position = Vector3(0.1 * side, 1.6, 0)
    end

    -- 身体环绕烟雾环（三Torus 交错旋转）
    for i, angle in ipairs({ 0, 30, 60 }) do
        local ring = root:CreateChild("SmokeRing" .. i)
        local rm = ring:CreateComponent("StaticModel")
        rm:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
        rm:SetMaterial(glowMat)
        ring.scale = Vector3(0.35 + i * 0.03, 0.35 + i * 0.03, 0.35 + i * 0.03)
        ring.position = Vector3(0, 0.2 + i * 0.28, 0)
        ring.rotation = Quaternion(angle, Vector3.UP) * Quaternion(12 + i * 5, Vector3.RIGHT)
    end

    -- 飘浮尖刺（Cone × 5 环绕，比之前多）
    for i = 1, 5 do
        local a = (i - 1) * 1.2566  -- 72度间隔
        local spike = root:CreateChild("Spike" .. i)
        local sm = spike:CreateComponent("StaticModel")
        sm:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        sm:SetMaterial(glowMat)
        spike.scale = Vector3(0.05, 0.18, 0.05)
        spike.position = Vector3(math.sin(a) * 0.48, 0.6 + (i % 2) * 0.3, math.cos(a) * 0.48)
        spike.rotation = Quaternion(180, Vector3.FORWARD)
    end

    -- 双眼（荧光绿）
    local eyeMat = makeGlow(Color(0.5, 1.0, 0.2, 1.0), 4.0)
    for _, side in ipairs({ -1, 1 }) do
        local eye = root:CreateChild("Eye")
        local em = eye:CreateComponent("StaticModel")
        em:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        em:SetMaterial(eyeMat)
        eye.scale = Vector3(0.07, 0.05, 0.05)
        eye.position = Vector3(0.11 * side, 1.4, 0.2)
    end

    -- 底部毒液倒锥
    local baseCone = root:CreateChild("BaseCone")
    local bcm = baseCone:CreateComponent("StaticModel")
    bcm:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
    bcm:SetMaterial(glowMat)
    baseCone.scale = Vector3(0.22, 0.25, 0.22)
    baseCone.position = Vector3(0, -0.05, 0)
    baseCone.rotation = Quaternion(180, Vector3.FORWARD)

    -- 绿色点光源
    local light = head:CreateComponent("Light")
    light.lightType = LIGHT_POINT
    light.castShadows = false
    light.range = 5.0
    light.color = Color(0.3, 0.9, 0.2, 1.0)
    light.brightness = 1.2
end

--- 构建升级 Boss 模型（更大更红，随等级缩放）
local function buildLevelBossModel(root, level)
    local cfg = GameConfig.Enemies.Boss
    local scaling = GameConfig.Enemies.LevelScaling
    local s = cfg.Scale + (level - 1) * scaling.LevelBossScale  -- 随等级增大
    local bodyMat = makeMat(Color(0.8, 0.05, 0.05, 1.0))  -- 更深的红色
    local headMat = makeMat(Color(1.0, 0.15, 0.0, 1.0))
    local armorMat = makeMat(Color(0.25, 0.02, 0.02, 1.0))

    -- 身体（大型）
    local body = root:CreateChild("Body")
    local bm = body:CreateComponent("StaticModel")
    bm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    bm:SetMaterial(bodyMat)
    body.scale = Vector3(0.9 * s, 1.3 * s, 0.6 * s)
    body.position = Vector3(0, 0.8 * s, 0)

    -- 胸甲
    local chest = root:CreateChild("ChestArmor")
    local cm = chest:CreateComponent("StaticModel")
    cm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    cm:SetMaterial(armorMat)
    chest.scale = Vector3(0.85 * s, 0.7 * s, 0.22 * s)
    chest.position = Vector3(0, 1.05 * s, 0.32 * s)

    -- 腰甲
    local waist = root:CreateChild("WaistArmor")
    local wm = waist:CreateComponent("StaticModel")
    wm:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    wm:SetMaterial(armorMat)
    waist.scale = Vector3(0.52 * s, 0.1 * s, 0.52 * s)
    waist.position = Vector3(0, 0.2 * s, 0)

    -- 头
    local head = root:CreateChild("Head")
    local hm = head:CreateComponent("StaticModel")
    hm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    hm:SetMaterial(headMat)
    head.scale = Vector3(0.55 * s, 0.55 * s, 0.55 * s)
    head.position = Vector3(0, 1.75 * s, 0)

    -- 下颚
    local jaw = root:CreateChild("Jaw")
    local jm = jaw:CreateComponent("StaticModel")
    jm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    jm:SetMaterial(headMat)
    jaw.scale = Vector3(0.42 * s, 0.15 * s, 0.38 * s)
    jaw.position = Vector3(0, 1.44 * s, 0.05 * s)

    -- 多对角（等级越高角越多，最多4对）
    local hornMat = makeGlow(Color(1.0, 0.2, 0.0, 1.0), 4.0)
    local hornPairs = math.min(math.floor(level / 2) + 1, 4)
    for p = 1, hornPairs do
        local spread = 0.15 + (p - 1) * 0.08
        local heightOff = (p - 1) * 0.15
        for _, side in ipairs({ -1, 1 }) do
            local horn = root:CreateChild("Horn")
            local hom = horn:CreateComponent("StaticModel")
            hom:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
            hom:SetMaterial(hornMat)
            horn.scale = Vector3(0.14 * s, (0.4 + heightOff) * s, 0.14 * s)
            horn.position = Vector3((spread + 0.05) * side * s, (2.05 + heightOff * 0.5) * s, 0)
        end
    end

    -- 双臂（上臂+前臂+拳头+肩甲）
    for _, side in ipairs({ -1, 1 }) do
        local upperArm = root:CreateChild("UpperArm")
        local uam = upperArm:CreateComponent("StaticModel")
        uam:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        uam:SetMaterial(bodyMat)
        upperArm.scale = Vector3(0.35 * s, 0.55 * s, 0.35 * s)
        upperArm.position = Vector3(0.65 * side * s, 0.85 * s, 0)

        local foreArm = root:CreateChild("ForeArm")
        local fam = foreArm:CreateComponent("StaticModel")
        fam:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        fam:SetMaterial(bodyMat)
        foreArm.scale = Vector3(0.28 * s, 0.5 * s, 0.28 * s)
        foreArm.position = Vector3(0.65 * side * s, 0.3 * s, 0.05 * s)

        local fist = root:CreateChild("Fist")
        local fm = fist:CreateComponent("StaticModel")
        fm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        fm:SetMaterial(bodyMat)
        fist.scale = Vector3(0.22 * s, 0.22 * s, 0.22 * s)
        fist.position = Vector3(0.65 * side * s, 0.05 * s, 0.05 * s)

        -- 肩甲
        local shoulder = root:CreateChild("ShoulderGuard")
        local sgm = shoulder:CreateComponent("StaticModel")
        sgm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        sgm:SetMaterial(armorMat)
        shoulder.scale = Vector3(0.42 * s, 0.15 * s, 0.42 * s)
        shoulder.position = Vector3(0.65 * side * s, 1.18 * s, 0)
    end

    -- 双腿
    for _, side in ipairs({ -1, 1 }) do
        local leg = root:CreateChild("Leg")
        local lm = leg:CreateComponent("StaticModel")
        lm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        lm:SetMaterial(bodyMat)
        leg.scale = Vector3(0.3 * s, 0.45 * s, 0.3 * s)
        leg.position = Vector3(0.28 * side * s, -0.05 * s, 0)

        local foot = root:CreateChild("Foot")
        local ftm = foot:CreateComponent("StaticModel")
        ftm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        ftm:SetMaterial(armorMat)
        foot.scale = Vector3(0.32 * s, 0.12 * s, 0.4 * s)
        foot.position = Vector3(0.28 * side * s, -0.3 * s, 0.05 * s)
    end

    -- 双眼（炽热发光）
    local eyeMat = makeGlow(Color(1.0, 0.8, 0.0, 1.0), 6.0)
    for _, side in ipairs({ -1, 1 }) do
        local eye = root:CreateChild("Eye")
        local em = eye:CreateComponent("StaticModel")
        em:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        em:SetMaterial(eyeMat)
        eye.scale = Vector3(0.12 * s, 0.1 * s, 0.07 * s)
        eye.position = Vector3(0.14 * side * s, 1.82 * s, 0.27 * s)
    end

    -- 背部尖刺群（等级越高越多）
    local spikeCount = math.min(2 + level, 5)
    local spikeMat = makeGlow(Color(1.0, 0.15, 0.0, 1.0), 2.5)
    for i = 1, spikeCount do
        local spike = root:CreateChild("BackSpike")
        local spm = spike:CreateComponent("StaticModel")
        spm:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        spm:SetMaterial(spikeMat)
        spike.scale = Vector3(0.08 * s, (0.2 + i * 0.06) * s, 0.08 * s)
        spike.position = Vector3((i - (spikeCount + 1) / 2) * 0.18 * s, 1.1 * s, -0.38 * s)
    end

    -- 脚下光环（Torus）
    local auraMat = makeGlow(Color(1.0, 0.1, 0.0, 1.0), 2.0)
    local auraRing = root:CreateChild("AuraRing")
    local arm = auraRing:CreateComponent("StaticModel")
    arm:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
    arm:SetMaterial(auraMat)
    auraRing.scale = Vector3(0.8 * s, 0.8 * s, 0.8 * s)
    auraRing.position = Vector3(0, 0.05, 0)

    -- 光环（更强烈）
    local light = head:CreateComponent("Light")
    light.lightType = LIGHT_POINT
    light.castShadows = false
    light.range = 10.0 + level * 2
    light.color = Color(1.0, 0.2, 0.0, 1.0)
    light.brightness = 2.0 + level * 0.3
end

-- ============================================================================
-- 属性缩放工具
-- ============================================================================

--- 根据玩家等级缩放敌人属性
---@param baseHP number
---@param baseDmg number
---@param baseSpeed number
---@param level number
---@return number hp
---@return number dmg
---@return number spd
local function scaleStats(baseHP, baseDmg, baseSpeed, level)
    local sc = GameConfig.Enemies.LevelScaling
    local lvl = math.max(0, level - 1)
    local hp  = math.floor(baseHP  * (1 + sc.HPMult * lvl))
    local dmg = math.floor(baseDmg * (1 + sc.DamageMult * lvl))
    local spd = baseSpeed * (1 + sc.SpeedMult * lvl)
    return hp, dmg, spd
end

-- ============================================================================
-- 在玩家周围随机位置生成
-- ============================================================================

local BOUNDARY_LIMIT = 390  -- 敌人刷新不超过边界

local function randomSpawnPos(playerPos)
    local waveCfg = GameConfig.Enemies.Wave
    for attempt = 1, 5 do
        local angle = math.random() * 6.28
        local dist = waveCfg.SpawnRadius.min + math.random() * (waveCfg.SpawnRadius.max - waveCfg.SpawnRadius.min)
        local x = playerPos.x + math.cos(angle) * dist
        local z = playerPos.z + math.sin(angle) * dist
        x = math.max(-BOUNDARY_LIMIT, math.min(BOUNDARY_LIMIT, x))
        z = math.max(-BOUNDARY_LIMIT, math.min(BOUNDARY_LIMIT, z))
        -- 安全区内不刷怪
        if not SafeZoneSystem.IsPositionInSafeZone(x, z) then
            return x, z
        end
    end
    -- 兜底：安全区边缘外5米
    local angle = math.random() * 6.28
    local r = SafeZoneSystem.GetRadius() + 5.0
    local center = SafeZoneSystem.GetCenter()
    local x = center.x + math.cos(angle) * r
    local z = center.z + math.sin(angle) * r
    x = math.max(-BOUNDARY_LIMIT, math.min(BOUNDARY_LIMIT, x))
    z = math.max(-BOUNDARY_LIMIT, math.min(BOUNDARY_LIMIT, z))
    return x, z
end

-- ============================================================================
-- 生成敌人
-- ============================================================================

local function spawnEnemy(type, x, z, patrolRadius, levelOverride)
    local id = "enemy_" .. nextId_
    nextId_ = nextId_ + 1

    local groundY = getGroundY(x, z, 0)
    local node = scene_:CreateChild(id)
    node.position = Vector3(x, groundY, z)
    node:SetVar("EnemyId", Variant(id))

    local level = levelOverride or monsterLevel_

    if type == "melee" then
        buildMeleeModel(node)
    elseif type == "boss" then
        buildBossModel(node)
    elseif type == "levelBoss" then
        buildLevelBossModel(node, level)
    elseif type == "dragonBoss" then
        buildDragonBossModel(node, level)
        -- 龙Boss 在空中生成
        local dCfg = GameConfig.Enemies.DragonBoss
        node.position = Vector3(x, groundY + dCfg.FlyHeight, z)
    elseif type == "ultimateBoss" then
        buildUltimateBossModel(node, level)
    elseif type == "eliteMelee" then
        buildEliteMeleeModel(node)
    elseif type == "eliteRanged" then
        buildEliteRangedModel(node)
    elseif type == "eliteAOE" then
        buildEliteAOEModel(node)
    elseif type == "eliteDebuff" then
        buildEliteDebuffModel(node)
    else
        buildRangedModel(node)
    end

    -- 添加 Kinematic 物理体（阻挡玩家但不受物理力影响）
    do
        local scale = (type == "ultimateBoss") and 3.5
            or (type == "dragonBoss") and 2.5
            or (type == "boss" or type == "levelBoss") and 2.0
            or 1.0
        local rb = node:CreateComponent("RigidBody")
        rb.mass = 0
        rb.kinematic = true
        rb.collisionLayer = CollisionLayerKinematic
        rb.collisionMask = CollisionMaskKinematic
        rb.friction = 0.3
        local cs = node:CreateComponent("CollisionShape")
        cs:SetCapsule(0.6 * scale, 1.8 * scale, Vector3(0, 0.9 * scale, 0))
    end

    -- 获取基础配置
    local cfg
    local aiType  -- AI 类型：melee 或 ranged 或 dragon 或 ultimate
    if type == "ultimateBoss" then
        cfg = GameConfig.Enemies.UltimateBoss
        aiType = "ultimate"
    elseif type == "dragonBoss" then
        cfg = GameConfig.Enemies.DragonBoss
        aiType = "dragon"
    elseif type == "boss" or type == "levelBoss" then
        cfg = GameConfig.Enemies.Boss
        aiType = "melee"
    elseif type == "eliteMelee" then
        cfg = GameConfig.Enemies.EliteMelee
        aiType = "melee"
    elseif type == "eliteRanged" then
        cfg = GameConfig.Enemies.EliteRanged
        aiType = "ranged"
    elseif type == "eliteAOE" then
        cfg = GameConfig.Enemies.EliteAOE
        aiType = "eliteAOE"
    elseif type == "eliteDebuff" then
        cfg = GameConfig.Enemies.EliteDebuff
        aiType = "eliteDebuff"
    elseif type == "melee" then
        cfg = GameConfig.Enemies.Melee
        aiType = "melee"
    else
        cfg = GameConfig.Enemies.Ranged
        aiType = "ranged"
    end

    -- 应用等级缩放
    local chaseSpeed = cfg.ChaseSpeed or cfg.FlySpeed or cfg.MoveSpeed or 2.0
    local hp, dmg, spd = scaleStats(cfg.HP, cfg.Damage, chaseSpeed, level)

    -- 难度缩放
    hp  = math.floor(hp  * DifficultySystem.GetHPMult())
    dmg = math.floor(dmg * DifficultySystem.GetDmgMult())
    spd = spd * DifficultySystem.GetSpdMult()

    -- 升级 Boss 额外加成
    if type == "levelBoss" then
        local sc = GameConfig.Enemies.LevelScaling
        hp = math.floor(hp * (1 + sc.LevelBossScale * level))
        dmg = math.floor(dmg * (1 + sc.LevelBossScale * level * 0.5))
    end

    -- 龙Boss 额外加成（每10级 +30% 血量 / +20% 伤害）
    if type == "dragonBoss" then
        local dragonLevelMult = math.floor(level / 10)
        hp = math.floor(hp * (1 + 0.30 * dragonLevelMult))
        dmg = math.floor(dmg * (1 + 0.20 * dragonLevelMult))
    end

    -- 终极Boss 额外加成（随怪物等级大幅增强）
    if type == "ultimateBoss" then
        hp = math.floor(hp * (1 + 0.25 * (level - 1)))
        dmg = math.floor(dmg * (1 + 0.15 * (level - 1)))
    end

    local enemyData = {
        id = id, type = type, node = node,
        hp = hp, maxHP = hp,
        scaledDamage = dmg,
        scaledSpeed = spd,
        aiType = aiType,
        monsterLvl = level,  -- 出生时的怪物等级（用于经验计算）
        state = "IDLE",
        spawnPos = Vector3(x, groundY, z),
        patrolRadius = patrolRadius or 5.0,
        patrolTarget = nil,
        attackTimer = 0, stateTimer = 1.0 + math.random() * 2.0,
        flashTimer = 0, freezeTimer = 0,
        slowTimer = 0, burnTimer = 0, burnDPS = 0,
        bobPhase = math.random() * 6.28,
        isBoss = (type == "boss" or type == "levelBoss" or type == "dragonBoss" or type == "ultimateBoss"),
    }

    -- 精英AOE 额外状态
    if type == "eliteAOE" then
        enemyData.aoeCD = cfg.AOECooldown * 0.5  -- 初始半CD
    end

    -- 龙Boss 额外状态
    if type == "dragonBoss" then
        enemyData.circleAngle = math.random() * 6.28  -- 盘旋角度
        enemyData.diveTimer = cfg.DiveCooldown          -- 俯冲计时
        enemyData.breathTimer = cfg.BreathCooldown * 0.5 -- 吐息计时（初始半CD）
        enemyData.diveTarget = nil                       -- 俯冲目标点
        enemyData.isDiving = false                       -- 是否正在俯冲
        enemyData.bodyWave = 0                           -- 身体波浪动画
    end

    -- 终极Boss 额外状态
    if type == "ultimateBoss" then
        enemyData.stompCD = cfg.StompCooldown * 0.5   -- 初始半CD
        enemyData.rainCD = cfg.RainCooldown
        enemyData.teleCD = cfg.TeleportCooldown
        enemyData.laserCD = cfg.LaserCooldown
        enemyData.summonCD = cfg.SummonCooldown
        enemyData.laserActive = false
        enemyData.laserTimer = 0
        enemyData.laserAngle = 0
        enemyData.laserTickTimer = 0
        enemyData.effects = {}
    end

    -- 难度视觉特效：困难/炼狱模式给敌人添加发光光环
    local diffGlow = DifficultySystem.GetGlowIntensity()
    if diffGlow > 0 then
        local gc = DifficultySystem.GetGlowColor()
        local auraNode = node:CreateChild("DiffAura")
        auraNode.scale = Vector3(1.2, 1.2, 1.2)
        auraNode.position = Vector3(0, 0.9, 0)
        local auraMdl = auraNode:CreateComponent("StaticModel")
        auraMdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        auraMdl:SetMaterial(makeGlow(Color(gc[1], gc[2], gc[3], 0.3), diffGlow))
    end
    -- 难度体型缩放（炼狱模式敌人更大）
    local diffScale = DifficultySystem.GetScaleMult()
    if diffScale > 1.0 then
        node.scale = node.scale * diffScale
    end

    enemies_[id] = enemyData
    return id
end

-- ============================================================================
-- 近战 AI
-- ============================================================================

local function getMeleeCfg(e)
    if e.type == "levelBoss" or e.type == "boss" then
        return GameConfig.Enemies.Boss
    elseif e.type == "eliteMelee" then
        return GameConfig.Enemies.EliteMelee
    elseif e.type == "eliteAOE" then
        return GameConfig.Enemies.EliteAOE
    else
        return GameConfig.Enemies.Melee
    end
end

local function updateMeleeAI(e, dt, playerPos)
    local pos = e.node.position
    local dist = distXZ(pos, playerPos)
    local cfg = getMeleeCfg(e)
    local chaseSpeed = e.scaledSpeed or cfg.ChaseSpeed
    local damage = e.scaledDamage or cfg.Damage
    e.attackTimer = math.max(0, e.attackTimer - dt)

    if e.state == "IDLE" then
        -- 平滑钳制 Y 到地面
        local gy = getGroundY(pos.x, pos.z, nil)
        if gy then smoothCorrectY(e, gy, dt) end

        e.stateTimer = e.stateTimer - dt
        if dist < cfg.DetectRange then
            e.state = "CHASE"
        elseif e.stateTimer <= 0 then
            local a = math.random() * 6.28
            local r = math.random() * e.patrolRadius
            e.patrolTarget = Vector3(e.spawnPos.x + math.cos(a) * r, 0, e.spawnPos.z + math.sin(a) * r)
            e.patrolTarget.y = getGroundY(e.patrolTarget.x, e.patrolTarget.z, pos.y)
            e.state = "PATROL"
        end

    elseif e.state == "PATROL" then
        if dist < cfg.DetectRange then e.state = "CHASE"; return end
        if e.patrolTarget then
            local dir = dirXZ(pos, e.patrolTarget)
            local np = pos + dir * (cfg.PatrolSpeed or 1.5) * dt
            -- 平滑修正 Y
            local targetY = getGroundY(np.x, np.z, pos.y)
            local diffY = targetY - pos.y
            if math.abs(diffY) < 0.05 then
                np.y = pos.y
            elseif math.abs(diffY) < 3.0 then
                np.y = pos.y + diffY * math.min(1.0, 10.0 * dt)
            else
                np.y = targetY
            end
            if not isBlockedByBuilding(pos, np) then
                e.node.position = np
            else
                e.state = "IDLE"; e.stateTimer = 1.0; return
            end
            faceToward(e.node, e.patrolTarget)
            if distXZ(e.node.position, e.patrolTarget) < 0.5 then
                e.state = "IDLE"
                e.stateTimer = 2.0 + math.random() * 2.0
            end
        end

    elseif e.state == "CHASE" then
        if dist > cfg.DetectRange * 1.5 then
            e.patrolTarget = Vector3(e.spawnPos.x, e.spawnPos.y, e.spawnPos.z)
            e.state = "PATROL"; return
        end
        if dist < cfg.AttackRange then e.state = "ATTACK"; return end
        local dir = dirXZ(pos, playerPos)
        local spdMult = (e.slowTimer and e.slowTimer > 0) and 0.5 or 1.0
        local np = pos + dir * chaseSpeed * spdMult * dt
        -- 平滑修正 Y，避免瞬间跳跃
        local targetY = getGroundY(np.x, np.z, pos.y)
        local diffY = targetY - pos.y
        if math.abs(diffY) < 0.05 then
            np.y = pos.y  -- 死区不修正
        elseif math.abs(diffY) < 3.0 then
            np.y = pos.y + diffY * math.min(1.0, 10.0 * dt)
        else
            np.y = targetY
        end
        -- 防止碰撞体重叠：与玩家保持最小安全距离（敌人半径 + 玩家半径 + 余量）
        local safeRadius = 0.3 * (e.scale or 1.0) + 0.4 + 0.15
        local newDist = distXZ(np, playerPos)
        if newDist >= safeRadius then
            if not isBlockedByBuilding(pos, np) then
                e.node.position = np
            end
        end
        faceToward(e.node, playerPos)

    elseif e.state == "ATTACK" then
        -- 平滑钳制 Y 到地面
        local gy = getGroundY(pos.x, pos.z, nil)
        if gy then smoothCorrectY(e, gy, dt) end

        faceToward(e.node, playerPos)
        if dist > cfg.AttackRange * 1.3 then e.state = "CHASE"; return end
        if e.attackTimer <= 0 then
            PlayerHealth.TakeDamage(damage)
            e.attackTimer = cfg.AttackCooldown
        end
    end
end

-- ============================================================================
-- 远程 AI
-- ============================================================================

local function getRangedCfg(e)
    if e.type == "eliteRanged" then
        return GameConfig.Enemies.EliteRanged
    elseif e.type == "eliteDebuff" then
        return GameConfig.Enemies.EliteDebuff
    else
        return GameConfig.Enemies.Ranged
    end
end

local function updateRangedAI(e, dt, playerPos)
    local pos = e.node.position
    local dist = distXZ(pos, playerPos)
    local cfg = getRangedCfg(e)
    local moveSpeed = e.scaledSpeed or cfg.MoveSpeed
    if e.slowTimer and e.slowTimer > 0 then moveSpeed = moveSpeed * 0.5 end
    local damage = e.scaledDamage or cfg.Damage
    e.attackTimer = math.max(0, e.attackTimer - dt)

    -- 旋转所有 Ring 子节点
    local ring = e.node:GetChild("Ring")
    if ring then ring.rotation = ring.rotation * Quaternion(dt * 90, Vector3.UP) end
    local ring2 = e.node:GetChild("Ring2")
    if ring2 then ring2.rotation = ring2.rotation * Quaternion(dt * -120, Vector3.UP) end

    -- 浮动高度（基于地面的固定悬浮）
    e.bobPhase = e.bobPhase + dt * 2.0
    local floatOffset = 0.3 + math.sin(e.bobPhase) * 0.15

    if e.state == "IDLE" then
        -- 平滑钳制 Y 到地面浮空高度
        local gy = getGroundY(pos.x, pos.z, nil)
        if gy then smoothCorrectY(e, gy + floatOffset, dt) end

        e.stateTimer = e.stateTimer - dt
        if dist < cfg.DetectRange then
            e.state = "ATTACK"
        elseif e.stateTimer <= 0 then
            local a = math.random() * 6.28
            local r = math.random() * e.patrolRadius
            e.patrolTarget = Vector3(e.spawnPos.x + math.cos(a) * r, 0, e.spawnPos.z + math.sin(a) * r)
            e.state = "PATROL"
        end

    elseif e.state == "PATROL" then
        if dist < cfg.DetectRange then e.state = "ATTACK"; return end
        if e.patrolTarget then
            local dir = dirXZ(pos, e.patrolTarget)
            local nx = pos.x + dir.x * moveSpeed * dt
            local nz = pos.z + dir.z * moveSpeed * dt
            local np = Vector3(nx, pos.y, nz)
            if not isBlockedByBuilding(pos, np) then
                local gy = getGroundY(nx, nz, pos.y - floatOffset)
                e.node.position = Vector3(nx, gy + floatOffset, nz)
            else
                e.state = "IDLE"; e.stateTimer = 1.0; return
            end
            faceToward(e.node, e.patrolTarget)
            if distXZ(e.node.position, e.patrolTarget) < 0.5 then
                e.state = "IDLE"
                e.stateTimer = 2.0 + math.random() * 2.0
            end
        end

    elseif e.state == "ATTACK" then
        -- 平滑钳制浮空高度
        local gy = getGroundY(pos.x, pos.z, nil)
        if gy then smoothCorrectY(e, gy + floatOffset, dt) end

        faceToward(e.node, playerPos)
        if dist > cfg.DetectRange * 1.5 then
            e.patrolTarget = Vector3(e.spawnPos.x, e.spawnPos.y, e.spawnPos.z)
            e.state = "PATROL"; return
        end
        if dist < cfg.RetreatRange then e.state = "RETREAT"; return end
        if e.attackTimer <= 0 then
            EnemyManager.ShootProjectile(e, playerPos)
            e.attackTimer = cfg.AttackCooldown
        end

    elseif e.state == "RETREAT" then
        faceToward(e.node, playerPos)
        if dist > cfg.RetreatRange * 2 then e.state = "ATTACK"; return end
        local dir = dirXZ(playerPos, pos)
        local nx = pos.x + dir.x * moveSpeed * 1.5 * dt
        local nz = pos.z + dir.z * moveSpeed * 1.5 * dt
        local np = Vector3(nx, pos.y, nz)
        if not isBlockedByBuilding(pos, np) then
            local gy = getGroundY(nx, nz, pos.y - floatOffset)
            e.node.position = Vector3(nx, gy + floatOffset, nz)
        end
    end
end

-- ============================================================================
-- 炼狱术士 AI（精英AOE：近距离地面冲击波）
-- ============================================================================

local function spawnAOEBlast(e, playerPos)
    -- 在脚下生成扩散光环视觉效果
    local pos = e.node.position
    local blastNode = scene_:CreateChild("AOEBlast")
    blastNode.position = Vector3(pos.x, pos.y + 0.1, pos.z)
    local mdl = blastNode:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
    mdl:SetMaterial(makeGlow(GameConfig.Enemies.EliteAOE.GlowColor, 4.0))
    blastNode.scale = Vector3(0.1, 0.1, 0.1)

    local pl = blastNode:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = 8.0
    pl.color = Color(1.0, 0.4, 0.05, 1.0)
    pl.brightness = 3.0

    -- 用 projectile 表来管理生命周期和扩散动画
    table.insert(projectiles_, {
        node = blastNode,
        dir = Vector3.ZERO,
        speed = 0,
        damage = e.scaledDamage or GameConfig.Enemies.EliteAOE.Damage,
        life = 0.6,
        isAOEBlast = true,
        aoeRange = GameConfig.Enemies.EliteAOE.AOERange,
        aoeOrigin = Vector3(pos.x, pos.y, pos.z),
        aoeDamaged = false,  -- 只造成一次伤害
        expandTimer = 0,
    })
end

local function updateEliteAOEAI(e, dt, playerPos)
    local pos = e.node.position
    local dist = distXZ(pos, playerPos)
    local cfg = GameConfig.Enemies.EliteAOE
    local chaseSpeed = e.scaledSpeed or cfg.ChaseSpeed
    local damage = e.scaledDamage or cfg.Damage
    e.attackTimer = math.max(0, e.attackTimer - dt)

    -- 火焰环旋转动画
    local fireRing = e.node:GetChild("FireRing")
    if fireRing then fireRing.rotation = fireRing.rotation * Quaternion(dt * 120, Vector3.UP) end

    if e.state == "IDLE" then
        local gy = getGroundY(pos.x, pos.z, nil)
        if gy then smoothCorrectY(e, gy, dt) end
        e.stateTimer = e.stateTimer - dt
        if dist < cfg.DetectRange then
            e.state = "CHASE"
        elseif e.stateTimer <= 0 then
            local a = math.random() * 6.28
            local r = math.random() * e.patrolRadius
            local ptx = e.spawnPos.x + math.cos(a) * r
            local ptz = e.spawnPos.z + math.sin(a) * r
            e.patrolTarget = Vector3(ptx, getGroundY(ptx, ptz, pos.y) or pos.y, ptz)
            e.state = "PATROL"
        end

    elseif e.state == "PATROL" then
        if dist < cfg.DetectRange then e.state = "CHASE"; return end
        if e.patrolTarget then
            local dir = dirXZ(pos, e.patrolTarget)
            local np = pos + dir * (cfg.PatrolSpeed or 1.5) * dt
            -- 平滑修正 Y
            local tgtY = getGroundY(np.x, np.z, pos.y) or pos.y
            local dY = tgtY - pos.y
            if math.abs(dY) < 0.05 then np.y = pos.y
            elseif math.abs(dY) < 3.0 then np.y = pos.y + dY * math.min(1.0, 10.0 * dt)
            else np.y = tgtY end
            if not isBlockedByBuilding(pos, np) then
                e.node.position = np
            else
                e.state = "IDLE"; e.stateTimer = 1.0; return
            end
            faceToward(e.node, e.patrolTarget)
            if distXZ(e.node.position, e.patrolTarget) < 0.5 then
                e.state = "IDLE"
                e.stateTimer = 2.0 + math.random() * 2.0
            end
        end

    elseif e.state == "CHASE" then
        if dist > cfg.DetectRange * 1.5 then
            e.patrolTarget = Vector3(e.spawnPos.x, e.spawnPos.y, e.spawnPos.z)
            e.state = "PATROL"; return
        end
        if dist < cfg.AttackRange then e.state = "ATTACK"; return end
        local dir = dirXZ(pos, playerPos)
        local spdMult = (e.slowTimer and e.slowTimer > 0) and 0.5 or 1.0
        local np = pos + dir * chaseSpeed * spdMult * dt
        -- 平滑修正 Y
        local tgtY = getGroundY(np.x, np.z, pos.y) or pos.y
        local dY = tgtY - pos.y
        if math.abs(dY) < 0.05 then np.y = pos.y
        elseif math.abs(dY) < 3.0 then np.y = pos.y + dY * math.min(1.0, 10.0 * dt)
        else np.y = tgtY end
        if not isBlockedByBuilding(pos, np) then
            e.node.position = np
        end
        faceToward(e.node, playerPos)

    elseif e.state == "ATTACK" then
        local gy = getGroundY(pos.x, pos.z, nil)
        if gy then smoothCorrectY(e, gy, dt) end
        faceToward(e.node, playerPos)
        if dist > cfg.AttackRange * 1.3 then e.state = "CHASE"; return end
        if e.attackTimer <= 0 then
            spawnAOEBlast(e, playerPos)
            e.attackTimer = cfg.AOECooldown
        end
    end
end

-- ============================================================================
-- 瘟疫幽魂 AI（精英Debuff：远程减速+灼烧弹丸）
-- ============================================================================

local function shootDebuffProjectile(e, targetPos)
    local cfg = GameConfig.Enemies.EliteDebuff
    local startPos = e.node.position + Vector3(0, 1.0, 0)
    local aimPos = targetPos + Vector3(0, 1.0, 0)
    local dir = (aimPos - startPos):Normalized()

    local node = scene_:CreateChild("DebuffProjectile")
    node.position = startPos
    local mdl = node:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    mdl:SetMaterial(makeGlow(cfg.GlowColor, 4.0))
    node.scale = Vector3(0.2, 0.2, 0.2)

    local pl = node:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = 4.0
    pl.color = cfg.GlowColor
    pl.brightness = 2.0

    table.insert(projectiles_, {
        node = node,
        dir = dir,
        speed = cfg.ProjectileSpeed,
        damage = e.scaledDamage or cfg.Damage,
        life = 3.0,
        isDebuff = true,  -- 标记为debuff弹丸
    })
end

local function updateEliteDebuffAI(e, dt, playerPos)
    local pos = e.node.position
    local dist = distXZ(pos, playerPos)
    local cfg = GameConfig.Enemies.EliteDebuff
    local moveSpeed = e.scaledSpeed or cfg.MoveSpeed
    if e.slowTimer and e.slowTimer > 0 then moveSpeed = moveSpeed * 0.5 end
    e.attackTimer = math.max(0, e.attackTimer - dt)

    -- 烟雾环旋转动画
    local sr1 = e.node:GetChild("SmokeRing1")
    if sr1 then sr1.rotation = sr1.rotation * Quaternion(dt * 60, Vector3.UP) end
    local sr2 = e.node:GetChild("SmokeRing2")
    if sr2 then sr2.rotation = sr2.rotation * Quaternion(dt * -80, Vector3.UP) end

    -- 浮动
    e.bobPhase = e.bobPhase + dt * 2.0
    local floatOffset = 0.3 + math.sin(e.bobPhase) * 0.15

    if e.state == "IDLE" then
        local gy = getGroundY(pos.x, pos.z, nil)
        if gy then smoothCorrectY(e, gy + floatOffset, dt) end
        e.stateTimer = e.stateTimer - dt
        if dist < cfg.DetectRange then
            e.state = "ATTACK"
        elseif e.stateTimer <= 0 then
            local a = math.random() * 6.28
            local r = math.random() * e.patrolRadius
            e.patrolTarget = Vector3(e.spawnPos.x + math.cos(a) * r, 0, e.spawnPos.z + math.sin(a) * r)
            e.state = "PATROL"
        end

    elseif e.state == "PATROL" then
        if dist < cfg.DetectRange then e.state = "ATTACK"; return end
        if e.patrolTarget then
            local dir = dirXZ(pos, e.patrolTarget)
            local nx = pos.x + dir.x * moveSpeed * dt
            local nz = pos.z + dir.z * moveSpeed * dt
            local np = Vector3(nx, pos.y, nz)
            if not isBlockedByBuilding(pos, np) then
                local gy = getGroundY(nx, nz, pos.y - floatOffset)
                e.node.position = Vector3(nx, gy + floatOffset, nz)
            else
                e.state = "IDLE"; e.stateTimer = 1.0; return
            end
            faceToward(e.node, e.patrolTarget)
            if distXZ(e.node.position, e.patrolTarget) < 0.5 then
                e.state = "IDLE"
                e.stateTimer = 2.0 + math.random() * 2.0
            end
        end

    elseif e.state == "ATTACK" then
        local gy = getGroundY(pos.x, pos.z, nil)
        if gy then smoothCorrectY(e, gy + floatOffset, dt) end
        faceToward(e.node, playerPos)
        if dist > cfg.DetectRange * 1.5 then
            e.patrolTarget = Vector3(e.spawnPos.x, e.spawnPos.y, e.spawnPos.z)
            e.state = "PATROL"; return
        end
        -- 太近则后退
        if dist < cfg.RetreatRange then e.state = "RETREAT"; return end
        if e.attackTimer <= 0 then
            shootDebuffProjectile(e, playerPos)
            e.attackTimer = cfg.AttackCooldown
        end

    elseif e.state == "RETREAT" then
        faceToward(e.node, playerPos)
        if dist > cfg.RetreatRange * 2 then e.state = "ATTACK"; return end
        local dir = dirXZ(playerPos, pos)
        local nx = pos.x + dir.x * moveSpeed * 1.5 * dt
        local nz = pos.z + dir.z * moveSpeed * 1.5 * dt
        local np = Vector3(nx, pos.y, nz)
        if not isBlockedByBuilding(pos, np) then
            local gy = getGroundY(nx, nz, pos.y - floatOffset)
            e.node.position = Vector3(nx, gy + floatOffset, nz)
        end
    end
end

-- ============================================================================
-- 龙Boss AI（飞行 + 俯冲 + 暗紫吐息）
-- ============================================================================

local function shootDragonBreath(e, targetPos)
    local cfg = GameConfig.Enemies.DragonBoss
    local startPos = e.node.position + Vector3(0, -0.5, 0)
    local aimPos = targetPos + Vector3(0, 1.0, 0)
    local dir = (aimPos - startPos):Normalized()

    -- 发射3枚散射暗紫火球
    for i = -1, 1 do
        local node = scene_:CreateChild("DragonBreath")
        node.position = startPos
        local mdl = node:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        mdl:SetMaterial(makeGlow(cfg.BreathColor, 4.0))
        node.scale = Vector3(0.25, 0.25, 0.25)

        local pl = node:CreateComponent("Light")
        pl.lightType = LIGHT_POINT
        pl.castShadows = false
        pl.range = 5.0
        pl.color = cfg.BreathColor
        pl.brightness = 2.0

        -- 散射偏移
        local spread = Quaternion(i * 8, Vector3.UP) * dir
        table.insert(projectiles_, {
            node = node,
            dir = spread,
            speed = cfg.BreathSpeed,
            damage = e.scaledDamage or cfg.BreathDamage,
            life = 3.0,
        })
    end
end

local function updateDragonAI(e, dt, playerPos)
    local pos = e.node.position
    local dist = distXZ(pos, playerPos)
    local cfg = GameConfig.Enemies.DragonBoss
    local flySpeed = e.scaledSpeed or cfg.FlySpeed
    e.attackTimer = math.max(0, e.attackTimer - dt)

    -- 身体波浪动画（蛇形游动效果）
    e.bodyWave = e.bodyWave + dt * 3.0
    for i = 1, 5 do
        local seg = e.node:GetChild("BodySeg" .. i)
        if seg then
            local wave = math.sin(e.bodyWave + i * 0.8) * 0.15
            local origZ = (1.8 - i * 0.55) * (cfg.Scale + ((e.monsterLvl or 1) - 1) * 0.1)
            seg.position = Vector3(wave, 0, origZ)
        end
    end

    -- 光环旋转
    local aura = e.node:GetChild("AuraRing")
    if aura then
        aura.rotation = aura.rotation * Quaternion(dt * 60, Vector3.FORWARD)
    end

    -- 尾巴摆动
    local tail = e.node:GetChild("Tail")
    if tail then
        local tailSwing = math.sin(e.bodyWave * 1.5) * 15
        local s = cfg.Scale + ((e.monsterLvl or 1) - 1) * 0.1
        tail.position = Vector3(math.sin(e.bodyWave) * 0.2, 0, -1.2 * s)
    end

    if e.state == "IDLE" then
        -- 龙Boss 始终激活（超远感知）
        e.state = "CIRCLE"
        e.circleAngle = math.atan(pos.x - playerPos.x, pos.z - playerPos.z)

    elseif e.state == "CIRCLE" then
        -- 盘旋：围绕玩家上空飞行
        e.circleAngle = e.circleAngle + dt * flySpeed / cfg.CircleRadius
        local targetX = playerPos.x + math.sin(e.circleAngle) * cfg.CircleRadius
        local targetZ = playerPos.z + math.cos(e.circleAngle) * cfg.CircleRadius
        local gy = getGroundY(targetX, targetZ, pos.y - cfg.FlyHeight)
        local targetY = gy + cfg.FlyHeight + math.sin(e.bodyWave * 0.5) * 1.5  -- 上下浮动

        local targetPos3 = Vector3(targetX, targetY, targetZ)
        local dir = (targetPos3 - pos):Normalized()
        local newPos = pos + dir * flySpeed * dt
        e.node.position = newPos

        -- 龙头始终朝飞行方向
        faceToward(e.node, Vector3(targetX + math.sin(e.circleAngle + 0.5) * 2, newPos.y, targetZ + math.cos(e.circleAngle + 0.5) * 2))

        -- 吐息计时
        e.breathTimer = e.breathTimer - dt
        if e.breathTimer <= 0 and dist < 30 then
            shootDragonBreath(e, playerPos)
            e.breathTimer = cfg.BreathCooldown
            AudioManager.PlayEnemyDeath()  -- 临时用作吐息音效
        end

        -- 俯冲计时
        e.diveTimer = e.diveTimer - dt
        if e.diveTimer <= 0 and dist < 25 then
            e.state = "DIVE"
            local diveGy = getGroundY(playerPos.x, playerPos.z, 0)
            e.diveTarget = Vector3(playerPos.x, diveGy + 1.0, playerPos.z)
            e.isDiving = true
        end

    elseif e.state == "DIVE" then
        -- 俯冲攻击：快速飞向玩家位置
        if e.diveTarget then
            local dir = (e.diveTarget - pos):Normalized()
            local newPos = pos + dir * cfg.DiveSpeed * dt
            e.node.position = newPos
            faceToward(e.node, e.diveTarget)

            -- 到达目标或足够接近地面
            local distToTarget = (e.diveTarget - newPos):Length()
            if distToTarget < 2.0 then
                -- 俯冲落地：范围伤害
                local damage = e.scaledDamage or cfg.Damage
                EnemyManager.AOEDamage(newPos, cfg.AttackRange, damage)

                -- 生成冲击波特效
                local shockNode = scene_:CreateChild("DragonShock")
                local shockGy = getGroundY(newPos.x, newPos.z, newPos.y)
                shockNode.position = Vector3(newPos.x, shockGy + 0.1, newPos.z)
                local sm = shockNode:CreateComponent("StaticModel")
                sm:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
                sm:SetMaterial(makeGlow(cfg.GlowColor, 4.0))
                shockNode.scale = Vector3(0.5, 0.5, 0.5)

                -- 将冲击波存为临时特效
                if not e.effects then e.effects = {} end
                table.insert(e.effects, { node = shockNode, life = 1.0, expandRate = 8.0 })

                -- 回到盘旋状态
                e.state = "RISE"
                e.isDiving = false
                e.diveTimer = cfg.DiveCooldown
            end
        end

    elseif e.state == "RISE" then
        -- 俯冲后回升到飞行高度
        local gy = getGroundY(pos.x, pos.z, 0)
        local targetY = gy + cfg.FlyHeight
        local newY = pos.y + cfg.FlySpeed * dt
        e.node.position = Vector3(pos.x, math.min(newY, targetY), pos.z)

        if newY >= targetY then
            e.state = "CIRCLE"
            e.circleAngle = math.atan(pos.x - playerPos.x, pos.z - playerPos.z)
        end
    end

    -- 更新临时特效（俯冲冲击波）
    if e.effects then
        local toRemove = {}
        for i, fx in ipairs(e.effects) do
            fx.life = fx.life - dt
            if fx.life <= 0 then
                fx.node:Remove()
                table.insert(toRemove, i)
            else
                local s = fx.node.scale.x + fx.expandRate * dt
                fx.node.scale = Vector3(s, s * 0.5, s)
                -- 淡出
                local alpha = fx.life
                fx.node:GetComponent("StaticModel"):SetMaterial(
                    makeGlow(Color(cfg.GlowColor.r, cfg.GlowColor.g, cfg.GlowColor.b, alpha), 4.0 * alpha)
                )
            end
        end
        for i = #toRemove, 1, -1 do
            table.remove(e.effects, toRemove[i])
        end
    end
end

-- ============================================================================
-- 终极Boss AI（深渊魔王 — 三阶段）
-- ============================================================================

--- 终极Boss 震地冲击（AOE）
local function ultimateStomp(e, playerPos)
    local cfg = GameConfig.Enemies.UltimateBoss
    local pos = e.node.position
    -- 对范围内玩家造成伤害
    local dist = distXZ(pos, playerPos)
    if dist <= cfg.StompRange then
        PlayerHealth.TakeDamage(cfg.StompDamage)
    end
    -- 生成冲击波特效
    local shockNode = scene_:CreateChild("UltimaStomp")
    local gy = getGroundY(pos.x, pos.z, pos.y)
    shockNode.position = Vector3(pos.x, gy + 0.1, pos.z)
    local sm = shockNode:CreateComponent("StaticModel")
    sm:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
    sm:SetMaterial(makeGlow(cfg.AuraColor, 5.0))
    shockNode.scale = Vector3(0.5, 0.5, 0.5)

    if not e.effects then e.effects = {} end
    table.insert(e.effects, { node = shockNode, life = 1.2, expandRate = 10.0, color = cfg.AuraColor })
    AudioManager.PlayEnemyDeath()
end

--- 终极Boss 弹幕雨（P2技能）
local function ultimateRain(e, playerPos)
    local cfg = GameConfig.Enemies.UltimateBoss
    local pos = e.node.position
    for i = 1, cfg.RainCount do
        local angle = (i - 1) * (6.28 / cfg.RainCount)
        local dir = Vector3(math.sin(angle), -0.3, math.cos(angle)):Normalized()
        local startPos = pos + Vector3(0, 2.5 * cfg.Scale, 0)

        local node = scene_:CreateChild("UltimaRain")
        node.position = startPos
        local mdl = node:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        mdl:SetMaterial(makeGlow(cfg.GlowColor, 4.0))
        node.scale = Vector3(0.2, 0.2, 0.2)

        local pl = node:CreateComponent("Light")
        pl.lightType = LIGHT_POINT
        pl.castShadows = false
        pl.range = 4.0
        pl.color = cfg.GlowColor
        pl.brightness = 2.0

        table.insert(projectiles_, {
            node = node,
            dir = dir,
            speed = cfg.RainSpeed,
            damage = cfg.RainDamage,
            life = 3.0,
        })
    end
end

--- 终极Boss 传送（P2技能）
local function ultimateTeleport(e, playerPos)
    local cfg = GameConfig.Enemies.UltimateBoss
    -- 传送到玩家身后 5-8 米处
    local angle = math.atan(playerPos.x - e.node.position.x, playerPos.z - e.node.position.z)
    local behindAngle = angle + math.pi
    local dist = 5.0 + math.random() * 3.0
    local tx = playerPos.x + math.sin(behindAngle) * dist
    local tz = playerPos.z + math.cos(behindAngle) * dist
    tx = math.max(-BOUNDARY_LIMIT, math.min(BOUNDARY_LIMIT, tx))
    tz = math.max(-BOUNDARY_LIMIT, math.min(BOUNDARY_LIMIT, tz))
    local gy = getGroundY(tx, tz, 0)
    e.node.position = Vector3(tx, gy, tz)
    e.spawnPos = Vector3(tx, gy, tz)

    -- 传送特效：在旧位置和新位置各生成闪光
    local flashNode = scene_:CreateChild("TeleFlash")
    flashNode.position = Vector3(tx, gy + 1.0, tz)
    local fm = flashNode:CreateComponent("StaticModel")
    fm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    fm:SetMaterial(makeGlow(cfg.AuraColor, 8.0))
    flashNode.scale = Vector3(2.0, 2.0, 2.0)
    if not e.effects then e.effects = {} end
    table.insert(e.effects, { node = flashNode, life = 0.5, expandRate = 4.0, color = cfg.AuraColor })
end

--- 终极Boss 激光扫射（P3技能） — 以旋转弹幕模拟
local function ultimateLaser(e, playerPos)
    local cfg = GameConfig.Enemies.UltimateBoss
    e.laserActive = true
    e.laserTimer = cfg.LaserDuration
    e.laserAngle = math.atan(playerPos.x - e.node.position.x, playerPos.z - e.node.position.z)
    e.laserTickTimer = 0.15  -- 每 0.15 秒发一弹
end

--- 终极Boss 召唤小怪（P3技能）
local function ultimateSummon(e, playerPos)
    local cfg = GameConfig.Enemies.UltimateBoss
    local pos = e.node.position
    for i = 1, cfg.SummonCount do
        local angle = math.random() * 6.28
        local dist = 3.0 + math.random() * 4.0
        local sx = pos.x + math.sin(angle) * dist
        local sz = pos.z + math.cos(angle) * dist
        sx = math.max(-BOUNDARY_LIMIT, math.min(BOUNDARY_LIMIT, sx))
        sz = math.max(-BOUNDARY_LIMIT, math.min(BOUNDARY_LIMIT, sz))
        local etype = pickEliteType()
        spawnEnemy(etype, sx, sz, 8.0, monsterLevel_)
    end
    AudioManager.PlayEnemyDeath()
end

local function updateUltimateBossAI(e, dt, playerPos)
    local pos = e.node.position
    local dist = distXZ(pos, playerPos)
    local cfg = GameConfig.Enemies.UltimateBoss
    local chaseSpeed = e.scaledSpeed or cfg.ChaseSpeed
    local damage = e.scaledDamage or cfg.Damage
    e.attackTimer = math.max(0, e.attackTimer - dt)

    -- 技能冷却更新
    e.stompCD = (e.stompCD or 0) - dt
    e.rainCD = (e.rainCD or 0) - dt
    e.teleCD = (e.teleCD or 0) - dt
    e.laserCD = (e.laserCD or 0) - dt
    e.summonCD = (e.summonCD or 0) - dt

    -- 判断阶段
    local hpRatio = e.hp / e.maxHP
    local phase = 1
    if hpRatio <= cfg.Phase3Threshold then
        phase = 3
    elseif hpRatio <= cfg.Phase2Threshold then
        phase = 2
    end

    -- 光环旋转动画
    local aura = e.node:GetChild("AuraRing")
    if aura then
        local rotSpeed = 60 + (phase - 1) * 40  -- 越到后期转越快
        aura.rotation = aura.rotation * Quaternion(dt * rotSpeed, Vector3.UP)
    end
    local backAura = e.node:GetChild("BackAura")
    if backAura then
        backAura.rotation = backAura.rotation * Quaternion(dt * 90, Vector3.FORWARD)
    end

    -- 平滑地面钳制
    local gy = getGroundY(pos.x, pos.z, nil)
    if gy then smoothCorrectY(e, gy, dt) end

    -- 激光扫射持续状态（P3）
    if e.laserActive then
        e.laserTimer = e.laserTimer - dt
        e.laserTickTimer = e.laserTickTimer - dt
        -- 激光旋转
        e.laserAngle = e.laserAngle + dt * 2.0
        if e.laserTickTimer <= 0 then
            e.laserTickTimer = 0.15
            -- 沿激光方向发射弹幕
            local ldir = Vector3(math.sin(e.laserAngle), 0, math.cos(e.laserAngle))
            local startPos = pos + Vector3(0, 1.5 * cfg.Scale, 0)
            local node = scene_:CreateChild("UltimaLaser")
            node.position = startPos
            local mdl = node:CreateComponent("StaticModel")
            mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
            mdl:SetMaterial(makeGlow(cfg.HornColor, 5.0))
            node.scale = Vector3(0.15, 0.15, 0.15)
            table.insert(projectiles_, {
                node = node,
                dir = ldir,
                speed = 18.0,
                damage = cfg.LaserDamage,
                life = 2.0,
            })
        end
        if e.laserTimer <= 0 then
            e.laserActive = false
        end
        -- 激光期间不移动
        faceToward(e.node, playerPos)
        return
    end

    -- 基本 AI 状态机
    if e.state == "IDLE" then
        if dist < cfg.DetectRange then
            e.state = "CHASE"
        end

    elseif e.state == "CHASE" then
        faceToward(e.node, playerPos)

        -- P3 狂暴加速
        local speedMult = (phase == 3) and 1.5 or 1.0
        local dir = dirXZ(pos, playerPos)
        local np = pos + dir * chaseSpeed * speedMult * dt
        -- 平滑修正 Y
        local tgtY = getGroundY(np.x, np.z, pos.y) or pos.y
        local dY = tgtY - pos.y
        if math.abs(dY) < 0.05 then np.y = pos.y
        elseif math.abs(dY) < 3.0 then np.y = pos.y + dY * math.min(1.0, 10.0 * dt)
        else np.y = tgtY end
        if not isBlockedByBuilding(pos, np) then
            e.node.position = np
        end

        -- 进入攻击范围
        if dist < cfg.AttackRange then
            e.state = "ATTACK"
            return
        end

        -- P1 震地
        if e.stompCD <= 0 and dist < cfg.StompRange then
            ultimateStomp(e, playerPos)
            e.stompCD = cfg.StompCooldown
        end

        -- P2 弹幕雨
        if phase >= 2 and e.rainCD <= 0 and dist < 20 then
            ultimateRain(e, playerPos)
            e.rainCD = cfg.RainCooldown
        end

        -- P2 传送
        if phase >= 2 and e.teleCD <= 0 and dist > 15 then
            ultimateTeleport(e, playerPos)
            e.teleCD = cfg.TeleportCooldown
        end

        -- P3 激光
        if phase >= 3 and e.laserCD <= 0 and dist < 25 then
            ultimateLaser(e, playerPos)
            e.laserCD = cfg.LaserCooldown
        end

        -- P3 召唤
        if phase >= 3 and e.summonCD <= 0 then
            ultimateSummon(e, playerPos)
            e.summonCD = cfg.SummonCooldown
        end

    elseif e.state == "ATTACK" then
        faceToward(e.node, playerPos)
        local gy2 = getGroundY(pos.x, pos.z, nil)
        if gy2 then smoothCorrectY(e, gy2, dt) end
        if dist > cfg.AttackRange * 1.5 then
            e.state = "CHASE"
            return
        end
        if e.attackTimer <= 0 then
            PlayerHealth.TakeDamage(damage)
            e.attackTimer = 1.5  -- 普通攻击间隔
            -- 攻击同时也可以用震地
            if e.stompCD <= 0 then
                ultimateStomp(e, playerPos)
                e.stompCD = cfg.StompCooldown
            end
        end
    end

    -- 更新特效
    if e.effects then
        local toRemove = {}
        for i, fx in ipairs(e.effects) do
            fx.life = fx.life - dt
            if fx.life <= 0 then
                fx.node:Remove()
                table.insert(toRemove, i)
            else
                local s = fx.node.scale.x + fx.expandRate * dt
                fx.node.scale = Vector3(s, s * 0.5, s)
                local alpha = fx.life
                local c = fx.color or cfg.AuraColor
                fx.node:GetComponent("StaticModel"):SetMaterial(
                    makeGlow(Color(c.r, c.g, c.b, alpha), 5.0 * alpha)
                )
            end
        end
        for i = #toRemove, 1, -1 do
            table.remove(e.effects, toRemove[i])
        end
    end
end

-- ============================================================================
-- 弹幕系统
-- ============================================================================

function EnemyManager.ShootProjectile(enemy, targetPos)
    local cfg = getRangedCfg(enemy)
    local startPos = enemy.node.position + Vector3(0, 1.0, 0)
    local aimPos = targetPos + Vector3(0, 1.0, 0)

    -- 精英远程弹幕颜色不同
    local isElite = (enemy.type == "eliteRanged")
    local projColor = isElite and Color(0.6, 0.2, 1.0, 1.0) or Color(0.3, 1.0, 0.3, 1.0)
    local projScale = isElite and 0.2 or 0.15

    local node = scene_:CreateChild("Projectile")
    node.position = startPos
    local mdl = node:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    mdl:SetMaterial(makeGlow(projColor, 4.0))
    node.scale = Vector3(projScale, projScale, projScale)

    local pl = node:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = isElite and 4.0 or 3.0
    pl.color = projColor
    pl.brightness = 1.5

    table.insert(projectiles_, {
        node = node,
        dir = (aimPos - startPos):Normalized(),
        speed = cfg.ProjectileSpeed,
        damage = enemy.scaledDamage or cfg.Damage,
        life = 3.0,
    })
end

local function updateProjectiles(dt, playerPos)
    local toRemove = {}
    for i, p in ipairs(projectiles_) do
        -- 节点已被外部移除（如场景重置），直接标记清除
        if not p.node then
            table.insert(toRemove, i)
            goto continueProj
        end
        p.life = p.life - dt
        if p.life <= 0 then
            table.insert(toRemove, i)
        elseif p.isAOEBlast then
            -- AOE 冲击波：扩散 Torus 动画 + 范围伤害（只命中一次）
            p.expandTimer = (p.expandTimer or 0) + dt
            local s = 0.1 + p.expandTimer * 12.0  -- 快速扩散
            p.node.scale = Vector3(s, s * 0.3, s)
            -- 在扩散到 AOE 范围时检测玩家
            if not p.aoeDamaged then
                local distToPlayer = distXZ(p.aoeOrigin, playerPos)
                if distToPlayer <= p.aoeRange then
                    PlayerHealth.TakeDamage(p.damage)
                    p.aoeDamaged = true
                end
            end
            -- 淡出光源
            local light = p.node:GetComponent("Light")
            if light then
                light.brightness = 3.0 * (p.life / 0.6)
            end
        else
            -- 普通弹丸 / debuff 弹丸：移动 + 碰撞检测
            p.node.position = p.node.position + p.dir * p.speed * dt
            if (p.node.position - playerPos):Length() < 0.8 then
                if p.isDebuff then
                    -- debuff弹丸：造成伤害 + 施加减速 + 灼烧
                    PlayerHealth.TakeDamage(p.damage)
                    local debuffCfg = GameConfig.Enemies.EliteDebuff
                    PlayerHealth.ApplyPlayerSlow(debuffCfg.SlowMult, debuffCfg.SlowDuration)
                    PlayerHealth.ApplyPlayerBurn(debuffCfg.BurnDPS, debuffCfg.BurnDuration)
                else
                    PlayerHealth.TakeDamage(p.damage)
                end
                table.insert(toRemove, i)
            end
        end
        ::continueProj::
    end
    for i = #toRemove, 1, -1 do
        local proj = projectiles_[toRemove[i]]
        if proj and proj.node then
            proj.node:Remove()
        end
        table.remove(projectiles_, toRemove[i])
    end
end

-- ============================================================================
-- 受伤闪白
-- ============================================================================

local function getEnemyCfg(e)
    if e.type == "ultimateBoss" then return GameConfig.Enemies.UltimateBoss
    elseif e.type == "dragonBoss" then return GameConfig.Enemies.DragonBoss
    elseif e.type == "boss" then return GameConfig.Enemies.Boss
    elseif e.type == "levelBoss" then return GameConfig.Enemies.Boss
    elseif e.type == "eliteMelee" then return GameConfig.Enemies.EliteMelee
    elseif e.type == "eliteRanged" then return GameConfig.Enemies.EliteRanged
    elseif e.type == "eliteAOE" then return GameConfig.Enemies.EliteAOE
    elseif e.type == "eliteDebuff" then return GameConfig.Enemies.EliteDebuff
    elseif e.type == "melee" then return GameConfig.Enemies.Melee
    else return GameConfig.Enemies.Ranged
    end
end

local function setBodyFlash(e, white)
    local bodyNode = e.node:GetChild("Body")
    if not bodyNode then return end
    local mdl = bodyNode:GetComponent("StaticModel")
    if not mdl then return end
    if white then
        -- 白色闪烁材质（makeMat 已缓存，同色只创建一次）
        mdl:SetMaterial(makeMat(Color(1.0, 1.0, 1.0, 1.0)))
    else
        -- 恢复原始体色（makeMat 已缓存）
        if e.type == "ultimateBoss" then
            mdl:SetMaterial(makeMat(GameConfig.Enemies.UltimateBoss.BodyColor))
        elseif e.type == "levelBoss" then
            mdl:SetMaterial(makeMat(Color(0.8, 0.05, 0.05, 1.0)))
        elseif e.type == "dragonBoss" then
            mdl:SetMaterial(makeMat(GameConfig.Enemies.DragonBoss.BodyColor))
        else
            local cfg = getEnemyCfg(e)
            mdl:SetMaterial(makeMat(cfg.BodyColor))
        end
    end
end

-- ============================================================================
-- 公开攻击接口（供 WeaponSystem 调用）
-- ============================================================================

--- 锥形攻击：命中视野内最近的一个敌人，返回是否命中
---@param camPos Vector3
---@param camDir Vector3
---@param range number
---@param dotMin number  视锥角度阈值 (0~1)
---@param damage number
---@return boolean
function EnemyManager.ConeAttack(camPos, camDir, range, dotMin, damage)
    local bestDist = range
    local bestId = nil
    for id, e in pairs(EnemyManager.GetAllEnemies()) do
        local center = e.node.position + Vector3(0, 0.7, 0)
        local toE = center - camPos
        local d = toE:Length()
        if d < range then
            local dot = camDir:DotProduct(toE:Normalized())
            if dot > dotMin and d < bestDist then
                bestDist = d
                bestId = id
            end
        end
    end
    if bestId then
        EnemyManager.DamageEnemy(bestId, damage)
        return true
    end
    return false
end

--- 近战锥形攻击：命中锥形内所有敌人（与 ConeAttack 区别：打全部而非单个）
---@param camPos Vector3
---@param camDir Vector3
---@param range number
---@param dotMin number
---@param damage number
---@return table hitIds  命中的敌人 ID 列表
function EnemyManager.MeleeConeAttack(camPos, camDir, range, dotMin, damage)
    local hitIds = {}
    for id, e in pairs(EnemyManager.GetAllEnemies()) do
        local center = e.node.position + Vector3(0, 0.7, 0)
        local toE = center - camPos
        local d = toE:Length()
        if d < range then
            local dot = camDir:DotProduct(toE:Normalized())
            if dot > dotMin then
                EnemyManager.DamageEnemy(id, damage)
                table.insert(hitIds, id)
            end
        end
    end
    return hitIds
end

--- 对指定敌人施加击退
---@param enemyId string
---@param dir Vector3  击退方向（水平）
---@param force number  击退初速度 m/s
function EnemyManager.ApplyKnockback(enemyId, dir, force)
    local e = enemies_[enemyId]
    if not e then return end
    -- Boss 抗击退
    local kbCfg = GameConfig.Knockback
    local resist = e.isBoss and kbCfg.BossResistance or 0
    local actualForce = force * (1.0 - resist)
    if actualForce < kbCfg.MinVelocity then return end
    -- 设置击退状态（水平方向）
    local flatDir = Vector3(dir.x, 0, dir.z)
    local len = math.sqrt(flatDir.x * flatDir.x + flatDir.z * flatDir.z)
    if len < 0.001 then return end
    flatDir = Vector3(flatDir.x / len, 0, flatDir.z / len)
    e.knockbackVel = flatDir * actualForce
    e.knockbackTimer = kbCfg.Duration
    -- 击退动画状态
    e.kbDir = flatDir                 -- 击退方向（用于倾斜朝向）
    e.kbTiltAngle = 0                 -- 当前倾斜角度（平滑过渡）
    e.kbTiltTarget = math.min(25 + actualForce * 2, 45)  -- 目标倾斜角（力度越大越倾斜）
    e.kbSquashTimer = 0.1             -- 受击挤压持续时间
    local s = e.node.scale
    e.kbOrigScale = Vector3(s.x, s.y, s.z)  -- 保存原始缩放
end

--- 穿透攻击：命中视野内所有敌人
---@return number hitCount
function EnemyManager.PierceAttack(camPos, camDir, range, dotMin, damage)
    local hits = 0
    for id, e in pairs(EnemyManager.GetAllEnemies()) do
        local center = e.node.position + Vector3(0, 0.7, 0)
        local toE = center - camPos
        local d = toE:Length()
        if d < range then
            local dot = camDir:DotProduct(toE:Normalized())
            if dot > dotMin then
                EnemyManager.DamageEnemy(id, damage)
                hits = hits + 1
            end
        end
    end
    return hits
end

--- AOE 范围伤害
---@param center Vector3
---@param range number
---@param damage number
---@return number hitCount
function EnemyManager.AOEDamage(center, range, damage)
    local hits = 0
    for id, e in pairs(EnemyManager.GetAllEnemies()) do
        if distXZ(e.node.position, center) <= range then
            EnemyManager.DamageEnemy(id, damage)
            hits = hits + 1
        end
    end
    return hits
end

--- 冻结范围内所有敌人
---@param center Vector3
---@param range number
---@param duration number
function EnemyManager.FreezeEnemies(center, range, duration)
    local freezeColor = Color(0.3, 0.5, 0.9, 1.0)
    for id, e in pairs(EnemyManager.GetAllEnemies()) do
        if distXZ(e.node.position, center) <= range then
            e.freezeTimer = duration
            -- 冰蓝色材质
            local bodyNode = e.node:GetChild("Body")
            if bodyNode then
                local mdl = bodyNode:GetComponent("StaticModel")
                if mdl then mdl:SetMaterial(makeMat(freezeColor)) end
            end
        end
    end
end

--- 矩形区域伤害（沿 forward 方向，length 长，halfWidth 半宽）
---@param origin Vector3  区域起点
---@param forward Vector3 方向（水平单位向量）
---@param length number   前方长度 m
---@param halfWidth number 半宽 m
---@param damage number   伤害值
---@return number hitCount
function EnemyManager.RectDamage(origin, forward, length, halfWidth, damage)
    local right = Vector3(forward.z, 0, -forward.x)
    local hits = 0
    for id, e in pairs(EnemyManager.GetAllEnemies()) do
        local offset = e.node.position - origin
        local fwdDist = offset.x * forward.x + offset.z * forward.z
        local sideDist = math.abs(offset.x * right.x + offset.z * right.z)
        if fwdDist >= -0.5 and fwdDist <= length and sideDist <= halfWidth then
            EnemyManager.DamageEnemy(id, damage)
            hits = hits + 1
        end
    end
    return hits
end

--- 矩形区域冻结
---@param origin Vector3
---@param forward Vector3
---@param length number
---@param halfWidth number
---@param duration number
function EnemyManager.FreezeEnemiesInRect(origin, forward, length, halfWidth, duration)
    local right = Vector3(forward.z, 0, -forward.x)
    local freezeColor = Color(0.3, 0.5, 0.9, 1.0)
    for id, e in pairs(EnemyManager.GetAllEnemies()) do
        local offset = e.node.position - origin
        local fwdDist = offset.x * forward.x + offset.z * forward.z
        local sideDist = math.abs(offset.x * right.x + offset.z * right.z)
        if fwdDist >= -0.5 and fwdDist <= length and sideDist <= halfWidth then
            e.freezeTimer = duration
            local bodyNode = e.node:GetChild("Body")
            if bodyNode then
                local mdl = bodyNode:GetComponent("StaticModel")
                if mdl then mdl:SetMaterial(makeMat(freezeColor)) end
            end
        end
    end
end

--- 获取最近的敌人
---@param pos Vector3
---@param range number
---@return string|nil enemyId
---@return table|nil enemyData
function EnemyManager.GetNearestEnemy(pos, range)
    local bestDist = range
    local bestId, bestE = nil, nil
    for id, e in pairs(enemies_) do
        local d = distXZ(pos, e.node.position)
        if d < bestDist then
            bestDist = d
            bestId = id
            bestE = e
        end
    end
    -- 同时搜索区域Boss
    local AreaBossManager = require("combat.AreaBossManager")
    for id, b in pairs(AreaBossManager.GetAllBosses()) do
        local d = distXZ(pos, b.node.position)
        if d < bestDist then
            bestDist = d
            bestId = id
            bestE = b
        end
    end
    return bestId, bestE
end

--- 获取所有敌人表（只读引用）— 合并区域Boss
---@return table
function EnemyManager.GetAllEnemies()
    -- 帧缓存：同一帧内只合并一次（用帧号判断）
    local curFrame = time:GetFrameNumber()
    if allEnemiesCache_ and allEnemiesCacheFrame_ == curFrame then
        return allEnemiesCache_
    end
    local merged = {}
    for id, e in pairs(enemies_) do
        merged[id] = e
    end
    local AreaBossManager = require("combat.AreaBossManager")
    for id, b in pairs(AreaBossManager.GetAllBosses()) do
        merged[id] = b
    end
    allEnemiesCache_ = merged
    allEnemiesCacheFrame_ = curFrame
    return merged
end

--- 对敌人施加减速DOT
---@param enemyId string
---@param duration number
function EnemyManager.ApplySlow(enemyId, duration)
    local e = enemies_[enemyId]
    if e then e.slowTimer = math.max(e.slowTimer or 0, duration) end
end

--- 对敌人施加灼烧DOT
---@param enemyId string
---@param dps number
---@param duration number
function EnemyManager.ApplyBurn(enemyId, dps, duration)
    local e = enemies_[enemyId]
    if e then
        e.burnTimer = math.max(e.burnTimer or 0, duration)
        e.burnDPS = dps
    end
end

-- ============================================================================
-- 半圆/圆形区域效果（组合技用）
-- ============================================================================

--- 半圆区域检测辅助：在 center 前方 forward 方向的半圆内
---@param epos Vector3
---@param center Vector3
---@param forward Vector3
---@param radius number
---@return boolean
local function inSemiCircle(epos, center, forward, radius)
    local dx = epos.x - center.x
    local dz = epos.z - center.z
    local distSq = dx * dx + dz * dz
    if distSq > radius * radius then return false end
    -- dot product with forward > 0 means in front hemisphere
    local dot = dx * forward.x + dz * forward.z
    return dot > 0
end

--- 半圆区域冻结
---@param center Vector3  玩家位置
---@param forward Vector3 朝向（水平单位向量）
---@param radius number   半径
---@param duration number 冻结时长
function EnemyManager.FreezeEnemiesInSemiCircle(center, forward, radius, duration)
    local freezeColor = Color(0.3, 0.5, 0.9, 1.0)
    for id, e in pairs(EnemyManager.GetAllEnemies()) do
        if inSemiCircle(e.node.position, center, forward, radius) then
            e.freezeTimer = math.max(e.freezeTimer or 0, duration)
            local bodyNode = e.node:GetChild("Body")
            if bodyNode then
                local mdl = bodyNode:GetComponent("StaticModel")
                if mdl then mdl:SetMaterial(makeMat(freezeColor)) end
            end
        end
    end
end

--- 半圆区域减速
---@param center Vector3
---@param forward Vector3
---@param radius number
---@param duration number
function EnemyManager.SlowEnemiesInSemiCircle(center, forward, radius, duration)
    for id, e in pairs(EnemyManager.GetAllEnemies()) do
        if inSemiCircle(e.node.position, center, forward, radius) then
            e.slowTimer = math.max(e.slowTimer or 0, duration)
        end
    end
end

--- 半圆区域灼烧
---@param center Vector3
---@param forward Vector3
---@param radius number
---@param dps number
---@param duration number
function EnemyManager.BurnEnemiesInSemiCircle(center, forward, radius, dps, duration)
    for id, e in pairs(EnemyManager.GetAllEnemies()) do
        if inSemiCircle(e.node.position, center, forward, radius) then
            e.burnTimer = math.max(e.burnTimer or 0, duration)
            e.burnDPS = dps
        end
    end
end

--- 半圆区域伤害
---@param center Vector3
---@param forward Vector3
---@param radius number
---@param damage number
---@return number hitCount
function EnemyManager.SemiCircleDamage(center, forward, radius, damage)
    local hits = 0
    for id, e in pairs(EnemyManager.GetAllEnemies()) do
        if inSemiCircle(e.node.position, center, forward, radius) then
            EnemyManager.DamageEnemy(id, damage)
            hits = hits + 1
        end
    end
    return hits
end

--- 圆形区域击飞（风遁）
--- 敌人被抛向空中，落地时受坠落伤害
---@param center Vector3  中心点
---@param radius number   范围半径
---@param launchHeight number 抛射高度 m
---@param fallDamage number   坠落伤害
function EnemyManager.LaunchEnemiesInCircle(center, radius, launchHeight, fallDamage)
    -- 需要的初始向上速度: v = sqrt(2 * g * h)
    local gravity = 9.81
    local v0 = math.sqrt(2 * gravity * launchHeight)
    for id, e in pairs(EnemyManager.GetAllEnemies()) do
        if distXZ(e.node.position, center) <= radius then
            -- 设置空中状态
            e.airborneVelY = v0
            e.airborneGroundY = e.node.position.y
            e.airborneFallDmg = fallDamage
            -- 冻结住让 AI 不干扰飞行
            e.freezeTimer = math.max(e.freezeTimer or 0, 6.0)
            -- 冰蓝材质
            local bodyNode = e.node:GetChild("Body")
            if bodyNode then
                local mdl = bodyNode:GetComponent("StaticModel")
                if mdl then mdl:SetMaterial(makeMat(Color(0.3, 0.5, 0.9, 1.0))) end
            end
        end
    end
end

--- 持续悬浮：将圆形范围内的敌人持续抬升到指定高度
--- 敌人在悬浮期间冻结AI，时间结束后统一坠落
---@param center Vector3
---@param radius number
---@param liftHeight number 悬浮高度
---@param duration number 持续时间
function EnemyManager.SustainLiftInCircle(center, radius, liftHeight, duration, fallDamage)
    for id, e in pairs(EnemyManager.GetAllEnemies()) do
        if distXZ(e.node.position, center) <= radius then
            e.liftTarget = e.node.position.y + liftHeight
            e.liftDuration = duration
            e.liftTimer = duration
            e.liftCenter = center
            e.liftRadius = radius
            e.liftGroundY = e.node.position.y
            e.liftFallDmg = fallDamage or 80
            e.freezeTimer = math.max(e.freezeTimer or 0, duration + 2.0)
            -- 绿色风属性材质提示
            local bodyNode = e.node:GetChild("Body")
            if bodyNode then
                local mdl = bodyNode:GetComponent("StaticModel")
                if mdl then mdl:SetMaterial(makeMat(Color(0.3, 0.9, 0.4, 1.0))) end
            end
        end
    end
end

--- 持续悬浮（半圆形区域）：将前方半圆范围内的敌人持续抬升到指定高度
---@param center Vector3
---@param forward Vector3  朝向（水平单位向量）
---@param radius number
---@param liftHeight number 悬浮高度
---@param duration number 持续时间
---@param fallDamage number 坠落伤害
function EnemyManager.SustainLiftInSemiCircle(center, forward, radius, liftHeight, duration, fallDamage)
    for id, e in pairs(EnemyManager.GetAllEnemies()) do
        if inSemiCircle(e.node.position, center, forward, radius) then
            e.liftTarget = e.node.position.y + liftHeight
            e.liftDuration = duration
            e.liftTimer = duration
            e.liftCenter = center
            e.liftRadius = radius
            e.liftForward = forward  -- 记录朝向用于后续半圆检测
            e.liftGroundY = e.node.position.y
            e.liftFallDmg = fallDamage or 80
            e.freezeTimer = math.max(e.freezeTimer or 0, duration + 2.0)
            local bodyNode = e.node:GetChild("Body")
            if bodyNode then
                local mdl = bodyNode:GetComponent("StaticModel")
                if mdl then mdl:SetMaterial(makeMat(Color(0.3, 0.9, 0.4, 1.0))) end
            end
        end
    end
end

--- 坠落伤害：让所有处于悬浮状态的敌人立即坠落并受到伤害
---@param fallDamage number 坠落伤害
function EnemyManager.DropLiftedEnemies(fallDamage)
    for id, e in pairs(EnemyManager.GetAllEnemies()) do
        if e.liftTimer and e.liftTimer > 0 then
            e.liftTimer = 0
            -- 设置坠落速度
            e.airborneVelY = 0
            e.airborneGroundY = e.liftGroundY or e.node.position.y
            e.airborneFallDmg = fallDamage
            -- 清除悬浮状态
            e.liftTarget = nil
            e.liftDuration = nil
            e.liftCenter = nil
            e.liftRadius = nil
            e.liftGroundY = nil
        end
    end
end

--- 将单个敌人悬浮（用于风柱持续区域检测，新进入的敌人也升空）
---@param id string
---@param liftHeight number
---@param remainTime number 剩余持续时间
---@param fallDamage number
function EnemyManager.LiftSingleEnemy(id, liftHeight, remainTime, fallDamage)
    local enemies = EnemyManager.GetAllEnemies()
    local e = enemies[id]
    if not e or not e.node then return end
    if e.liftTimer and e.liftTimer > 0 then return end -- 已在悬浮中
    e.liftTarget = e.node.position.y + liftHeight
    e.liftDuration = remainTime
    e.liftTimer = remainTime
    e.liftGroundY = e.node.position.y
    e.liftFallDmg = fallDamage or 80
    e.freezeTimer = math.max(e.freezeTimer or 0, remainTime + 2.0)
    local bodyNode = e.node:GetChild("Body")
    if bodyNode then
        local mdl = bodyNode:GetComponent("StaticModel")
        if mdl then mdl:SetMaterial(makeMat(Color(0.3, 0.9, 0.4, 1.0))) end
    end
end

--- 全图秒杀：对地图上所有敌人造成秒杀伤害
---@param damage number 伤害值（99999=秒杀）
---@return number hitCount
function EnemyManager.GlobalDamage(damage)
    local hits = 0
    for id, e in pairs(EnemyManager.GetAllEnemies()) do
        if e.node and e.hp and e.hp > 0 then
            EnemyManager.DamageEnemy(id, damage)
            hits = hits + 1
        end
    end
    return hits
end

--- 全图击飞：将地图上所有敌人击飞到指定高度
---@param launchHeight number 击飞高度
---@param fallDamage number 坠落伤害
---@param acceleratedFall boolean 是否加速坠落（秒杀效果）
---@return number hitCount
function EnemyManager.GlobalLaunch(launchHeight, fallDamage, acceleratedFall)
    local gravity = 9.81
    local v0 = math.sqrt(2 * gravity * launchHeight)
    local hits = 0
    for id, e in pairs(EnemyManager.GetAllEnemies()) do
        if e.node and e.hp and e.hp > 0 then
            e.airborneVelY = v0
            e.airborneGroundY = e.node.position.y
            e.airborneFallDmg = fallDamage
            if acceleratedFall then
                e.acceleratedFall = true  -- 标记加速坠落
            end
            e.freezeTimer = math.max(e.freezeTimer or 0, 8.0)
            local bodyNode = e.node:GetChild("Body")
            if bodyNode then
                local mdl = bodyNode:GetComponent("StaticModel")
                if mdl then mdl:SetMaterial(makeMat(Color(0.3, 0.9, 0.4, 1.0))) end
            end
            hits = hits + 1
        end
    end
    return hits
end

--- 全图击飞并击退：对所有敌人施加击退力
---@param center Vector3 爆炸中心
---@param knockDist number 击退距离（米）
---@param damage number 冲击伤害
---@return number hitCount
function EnemyManager.GlobalKnockback(center, knockDist, damage)
    local hits = 0
    for id, e in pairs(EnemyManager.GetAllEnemies()) do
        if e.node and e.hp and e.hp > 0 then
            EnemyManager.DamageEnemy(id, damage)
            -- 计算击退方向
            local dx = e.node.position.x - center.x
            local dz = e.node.position.z - center.z
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist < 0.1 then
                dx = math.random() - 0.5
                dz = math.random() - 0.5
                dist = math.sqrt(dx * dx + dz * dz)
            end
            local nx, nz = dx / dist, dz / dist
            -- 直接移动敌人位置模拟击退
            e.node.position = Vector3(
                e.node.position.x + nx * knockDist,
                e.node.position.y + 3.0,  -- 略微抬起
                e.node.position.z + nz * knockDist
            )
            -- 设置空中坠落
            e.airborneVelY = 5.0
            e.airborneGroundY = e.node.position.y - 3.0
            e.airborneFallDmg = 0  -- 冲击伤害已单独计算
            e.freezeTimer = math.max(e.freezeTimer or 0, 3.0)
            hits = hits + 1
        end
    end
    return hits
end

--- 吸引范围内敌人到指定位置
---@param center Vector3 吸引目标位置
---@param radius number 吸引范围
---@param pullStrength number 吸引力（每秒移动距离，乘dt使用）
function EnemyManager.PullEnemiesToPoint(center, radius, pullStrength)
    for id, e in pairs(EnemyManager.GetAllEnemies()) do
        if e.node and e.hp and e.hp > 0 then
            local dx = e.node.position.x - center.x
            local dz = e.node.position.z - center.z
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist <= radius and dist > 0.5 then
                local nx, nz = dx / dist, dz / dist
                local pull = math.min(pullStrength, dist - 0.3)
                e.node.position = Vector3(
                    e.node.position.x - nx * pull,
                    e.node.position.y,
                    e.node.position.z - nz * pull
                )
                e.freezeTimer = math.max(e.freezeTimer or 0, 0.5)
            end
        end
    end
end

--- 对圆形范围内敌人造成伤害
---@param center Vector3
---@param radius number
---@param damage number
---@return number hitCount
function EnemyManager.CircleDamage(center, radius, damage)
    local hits = 0
    for id, e in pairs(EnemyManager.GetAllEnemies()) do
        if e.node and e.hp and e.hp > 0 then
            local dx = e.node.position.x - center.x
            local dz = e.node.position.z - center.z
            if (dx * dx + dz * dz) <= radius * radius then
                EnemyManager.DamageEnemy(id, damage)
                hits = hits + 1
            end
        end
    end
    return hits
end

---@param enemyId string
---@param damage number
function EnemyManager.DamageEnemy(enemyId, damage)
    -- 区域Boss委托：ID以 "areaBoss_" 开头则转发
    if type(enemyId) == "string" and enemyId:sub(1, 9) == "areaBoss_" then
        local AreaBossManager = require("combat.AreaBossManager")
        AreaBossManager.DamageAreaBoss(enemyId, damage)
        return
    end

    local e = enemies_[enemyId]
    if not e then return end

    e.hp = e.hp - damage
    -- 闪白防抖：已在闪白中时只延长计时器，不重复切换材质
    if e.flashTimer <= 0 then
        setBodyFlash(e, true)
    end
    e.flashTimer = 0.15

    -- 命中粒子效果
    local epos = e.node.position
    local playerPos = playerGetPos_ and playerGetPos_() or nil
    if playerPos then
        local hitDir = dirXZ(playerPos, epos)
        spawnHitParticles(epos, hitDir, 5 + math.random(0, 3))
    else
        spawnHitParticles(epos, Vector3(0, 0, 1), 5)
    end

    if e.hp <= 0 then
        -- 掉落经验球（精英怪掉更多）
        local cfg = GameConfig.Leveling
        local orbCount
        if e.isBoss then
            orbCount = cfg.OrbsBoss
        elseif e.type == "eliteMelee" or e.type == "eliteRanged"
            or e.type == "eliteAOE" or e.type == "eliteDebuff" then
            orbCount = math.floor(cfg.OrbsNormal * 2)
        else
            orbCount = cfg.OrbsNormal
        end
        -- 传递怪物等级到经验球（每级 +20% 经验），难度倍率加成
        orbCount = math.max(1, math.floor(orbCount * DifficultySystem.GetXPMult()))
        XPOrbManager.SpawnOrbs(e.node.position, orbCount, e.monsterLvl or 1)

        -- 小怪有概率掉落血包（Boss/精英不掉）
        if not e.isBoss and e.type ~= "eliteMelee" and e.type ~= "eliteRanged"
            and e.type ~= "eliteAOE" and e.type ~= "eliteDebuff" then
            if math.random() < cfg.HealthDropChance then
                EnemyManager.SpawnHealthPack(e.node.position)
            end
        end

        -- 累计击杀
        killCount_ = killCount_ + 1

        -- 击杀货币奖励
        applyKillReward(e)

        -- 如果是定时 Boss 被击败，触发回调
        if enemyId == activeBossId_ then
            activeBossId_ = nil
            if onBossDefeated_ then
                onBossDefeated_(e.monsterLvl or 1)
            end
        end

        -- 如果是龙 Boss 被击败，触发回调
        if enemyId == activeDragonId_ then
            activeDragonId_ = nil
            if onDragonDefeated_ then
                onDragonDefeated_(e.monsterLvl or 1)
            end
        end

        -- 如果是终极 Boss 被击败，触发回调
        if enemyId == activeUltimateBossId_ then
            activeUltimateBossId_ = nil
            if onUltimateDefeated_ then
                onUltimateDefeated_(e.monsterLvl or 1)
            end
        end

        -- 敌人死亡回调（掉落系统）
        if onEnemyDeath_ then
            onEnemyDeath_(e, e.node.position)
        end

        -- 敌人死亡音效
        AudioManager.PlayEnemyDeath()

        e.node:Remove()
        enemies_[enemyId] = nil
    end
end

-- ============================================================================
-- 波次刷怪逻辑（时间驱动）
-- ============================================================================

--- 生成一小波敌人
local function spawnSmallWave(playerPos)
    -- 敌人数量上限检查
    local alive = getEnemyCount()
    if alive >= MAX_ALIVE_ENEMIES then return end

    waveNumber_ = waveNumber_ + 1
    local waveCfg = GameConfig.Enemies.Wave
    local scaling = GameConfig.Enemies.LevelScaling
    local extra = (monsterLevel_ - 1) * waveCfg.CountGrowth
    local count = math.min(waveCfg.SmallCount + extra, waveCfg.CountMax)
    -- 难度数量倍率
    count = math.max(1, math.floor(count * DifficultySystem.GetSpawnMult()))
    -- 不超过剩余容量
    count = math.min(count, MAX_ALIVE_ENEMIES - alive)

    local eliteChance = scaling.EliteChance + DifficultySystem.GetExtraEliteChance()
    for i = 1, count do
        local x, z = randomSpawnPos(playerPos)
        local etype
        -- 精英怪在达到解锁等级后有概率出现
        if monsterLevel_ >= scaling.EliteUnlockLevel and math.random() < eliteChance then
            etype = pickEliteType()
        else
            local rangedChance = math.min(0.2 + waveNumber_ * 0.03, 0.5)
            etype = (math.random() < rangedChance) and "ranged" or "melee"
        end
        spawnEnemy(etype, x, z, 5.0)
    end
    print("[EnemyManager] 小波 #" .. waveNumber_ .. "：" .. count .. " 个敌人 (怪物等级 " .. monsterLevel_ .. ")")
end

--- 生成一大波敌人
local function spawnBigWave(playerPos)
    -- 敌人数量上限检查
    local alive = getEnemyCount()
    if alive >= MAX_ALIVE_ENEMIES then return end

    waveNumber_ = waveNumber_ + 1
    local waveCfg = GameConfig.Enemies.Wave
    local scaling = GameConfig.Enemies.LevelScaling
    local extra = (monsterLevel_ - 1) * waveCfg.CountGrowth
    local count = math.min(waveCfg.BigCount + extra, waveCfg.CountMax)
    -- 难度数量倍率
    count = math.max(1, math.floor(count * DifficultySystem.GetSpawnMult()))
    -- 不超过剩余容量
    count = math.min(count, MAX_ALIVE_ENEMIES - alive)

    local eliteChance = scaling.EliteChance + DifficultySystem.GetExtraEliteChance()
    for i = 1, count do
        local x, z = randomSpawnPos(playerPos)
        local etype
        if monsterLevel_ >= scaling.EliteUnlockLevel and math.random() < eliteChance then
            etype = pickEliteType()
        else
            local rangedChance = math.min(0.25 + waveNumber_ * 0.03, 0.5)
            etype = (math.random() < rangedChance) and "ranged" or "melee"
        end
        spawnEnemy(etype, x, z, 5.0)
    end
    print("[EnemyManager] 大波 #" .. waveNumber_ .. "：" .. count .. " 个敌人 (怪物等级 " .. monsterLevel_ .. ")")
end

--- 怪物升级：每3分钟调用
local function upgradeMonsters()
    monsterLevel_ = monsterLevel_ + 1
    print("[EnemyManager] 怪物升级！当前怪物等级: " .. monsterLevel_)
end

--- 生成定时 Boss（10分钟一次）
local function spawnTimedBoss(playerPos)
    bossCount_ = bossCount_ + 1
    local x, z = randomSpawnPos(playerPos)
    local bossId = spawnEnemy("levelBoss", x, z, 10.0, monsterLevel_)
    activeBossId_ = bossId
    print("[EnemyManager] 定时 Boss #" .. bossCount_ .. " 出现！怪物等级: " .. monsterLevel_)
end

--- 获取当前怪物等级
---@return number
function EnemyManager.GetMonsterLevel()
    return monsterLevel_
end

--- 获取当前存活 Boss 的血量信息（供 HUD 显示，终极Boss > 龙Boss > 普通Boss）
---@return number|nil hp
---@return number|nil maxHP
---@return string|nil name
function EnemyManager.GetActiveBossHP()
    -- 终极Boss 最高优先级
    if activeUltimateBossId_ then
        local e = enemies_[activeUltimateBossId_]
        if e then
            local hpRatio = e.hp / e.maxHP
            local phaseName = "I"
            if hpRatio <= GameConfig.Enemies.UltimateBoss.Phase3Threshold then
                phaseName = "III"
            elseif hpRatio <= GameConfig.Enemies.UltimateBoss.Phase2Threshold then
                phaseName = "II"
            end
            return e.hp, e.maxHP, "👹 深渊魔王 P" .. phaseName
        else
            activeUltimateBossId_ = nil
        end
    end
    -- 龙Boss 次优先
    if activeDragonId_ then
        local e = enemies_[activeDragonId_]
        if e then
            return e.hp, e.maxHP, "🐉 暗龙 Lv." .. (e.monsterLvl or 1)
        else
            activeDragonId_ = nil
        end
    end
    if activeBossId_ then
        local e = enemies_[activeBossId_]
        if e then
            return e.hp, e.maxHP, "Boss Lv." .. (e.monsterLvl or 1)
        else
            activeBossId_ = nil
        end
    end
    -- 最低优先级：区域Boss（取最近的激活Boss）
    local AreaBossManager = require("combat.AreaBossManager")
    local abHP, abMaxHP, abName = AreaBossManager.GetNearestBossHP(playerGetPos_())
    if abHP then
        return abHP, abMaxHP, abName
    end
    return nil, nil, nil
end

--- 设置 Boss 击败回调
---@param cb function
function EnemyManager.OnBossDefeated(cb)
    onBossDefeated_ = cb
end

--- 设置龙Boss 击败回调
---@param cb function
function EnemyManager.OnDragonDefeated(cb)
    onDragonDefeated_ = cb
end

--- 设置敌人死亡回调（用于掉落系统）
---@param cb function(enemyData, deathPosition)
function EnemyManager.OnEnemyDeath(cb)
    onEnemyDeath_ = cb
end

--- 生成挑战龙Boss（玩家每10级触发）
---@param playerPos Vector3
---@param playerLevel number
function EnemyManager.SpawnDragonBoss(playerPos, playerLevel)
    -- 如果已有龙Boss存活，不重复生成
    if activeDragonId_ and enemies_[activeDragonId_] then
        print("[EnemyManager] 龙Boss 已存在，跳过生成")
        return
    end
    local angle = math.random() * 6.28
    local dist = 25 + math.random() * 10  -- 在25-35米处生成
    local x = playerPos.x + math.cos(angle) * dist
    local z = playerPos.z + math.sin(angle) * dist
    x = math.max(-BOUNDARY_LIMIT, math.min(BOUNDARY_LIMIT, x))
    z = math.max(-BOUNDARY_LIMIT, math.min(BOUNDARY_LIMIT, z))
    local dragonId = spawnEnemy("dragonBoss", x, z, 20.0, playerLevel)
    activeDragonId_ = dragonId
    print("[EnemyManager] 🐉 挑战龙Boss 出现！玩家等级: " .. playerLevel)
end

--- 生成终极Boss（每20分钟触发）
---@param playerPos Vector3
function EnemyManager.SpawnUltimateBoss(playerPos)
    -- 如果已有终极Boss存活，不重复生成
    if activeUltimateBossId_ and enemies_[activeUltimateBossId_] then
        print("[EnemyManager] 终极Boss 已存在，跳过生成")
        return
    end
    local angle = math.random() * 6.28
    local dist = 20 + math.random() * 10  -- 在20-30米处生成
    local x = playerPos.x + math.cos(angle) * dist
    local z = playerPos.z + math.sin(angle) * dist
    x = math.max(-BOUNDARY_LIMIT, math.min(BOUNDARY_LIMIT, x))
    z = math.max(-BOUNDARY_LIMIT, math.min(BOUNDARY_LIMIT, z))
    local bossId = spawnEnemy("ultimateBoss", x, z, 15.0, monsterLevel_)
    activeUltimateBossId_ = bossId
    if onUltimateSpawned_ then
        onUltimateSpawned_(monsterLevel_)
    end
    print("[EnemyManager] 👹 终极Boss 深渊魔王降临！怪物等级: " .. monsterLevel_)
end

--- 设置终极Boss 击败回调
---@param cb function
function EnemyManager.OnUltimateDefeated(cb)
    onUltimateDefeated_ = cb
end

--- 设置终极Boss 生成通知回调
---@param cb function
function EnemyManager.OnUltimateBossSpawned(cb)
    onUltimateSpawned_ = cb
end

--- 获取本局击杀数
---@return number
function EnemyManager.GetKillCount()
    return killCount_
end

--- 设置击杀数（开发者用）
---@param count number
function EnemyManager.SetKillCount(count)
    killCount_ = count
end

--- 获取/设置怪物等级（开发者用）
---@param level number
function EnemyManager.SetMonsterLevel(level)
    monsterLevel_ = math.max(1, math.floor(level))
end

--- 获取/设置波次计时器（开发者用）
function EnemyManager.GetTimers()
    return {
        smallWave = smallWaveTimer_,
        bigWave = bigWaveTimer_,
        upgrade = upgradeTimer_,
        boss = bossTimer_,
        ultimate = ultimateBossTimer_,
    }
end

---@param timers table { smallWave, bigWave, upgrade, boss, ultimate }
function EnemyManager.SetTimers(timers)
    if timers.smallWave then smallWaveTimer_ = timers.smallWave end
    if timers.bigWave then bigWaveTimer_ = timers.bigWave end
    if timers.upgrade then upgradeTimer_ = timers.upgrade end
    if timers.boss then bossTimer_ = timers.boss end
    if timers.ultimate then ultimateBossTimer_ = timers.ultimate end
end

--- 查询当前存活的 Boss 类型（用于 BGM 切换）
---@return string "ultimate"|"dragon"|"timed"|"none"
function EnemyManager.GetActiveBossType()
    if activeUltimateBossId_ and enemies_[activeUltimateBossId_] then
        return "ultimate"
    end
    if activeDragonId_ and enemies_[activeDragonId_] then
        return "dragon"
    end
    if activeBossId_ and enemies_[activeBossId_] then
        return "timed"
    end
    return "none"
end

--- 查询是否有任何敌人存活
---@return boolean
function EnemyManager.HasActiveEnemies()
    for _, _ in pairs(enemies_) do
        return true
    end
    return false
end

-- ============================================================================
-- 公共接口
-- ============================================================================

---@param scene Scene
---@param getPos function  返回玩家位置
---@param getCam function  返回相机节点
function EnemyManager.Init(scene, getPos, getCam)
    scene_ = scene
    playerGetPos_ = getPos
    playerGetCamNode_ = getCam

    -- 初始化四个计时器
    local waveCfg = GameConfig.Enemies.Wave
    smallWaveTimer_ = waveCfg.SmallInterval
    bigWaveTimer_   = waveCfg.BigInterval
    upgradeTimer_   = waveCfg.MonsterUpgrade
    bossTimer_      = waveCfg.BossInterval
    waveNumber_ = 0
    bossCount_ = 0
    monsterLevel_ = 1
    activeBossId_ = nil
    activeDragonId_ = nil
    activeUltimateBossId_ = nil
    ultimateBossTimer_ = 1200  -- 20分钟
    killCount_ = 0
    gameElapsed_ = 0
    healthPacks_ = {}
    nextHPId_ = 1

    -- 立即生成第一小波
    spawnSmallWave(getPos())
    print("[EnemyManager] 初始化完成，时间驱动刷怪已启动（终极Boss: 20分钟）")
end

---@param dt number
function EnemyManager.Update(dt)
    if PlayerHealth.IsDead() then return end

    -- 游戏全局时间累计（用于精英怪阶段解锁）
    gameElapsed_ = gameElapsed_ + dt

    local playerPos = playerGetPos_()
    local waveCfg = GameConfig.Enemies.Wave

    -- 难度间隔倍率
    local intervalMult = DifficultySystem.GetSpawnIntervalMult()

    -- 小波计时（15秒 × 难度间隔倍率）
    smallWaveTimer_ = smallWaveTimer_ - dt
    if smallWaveTimer_ <= 0 then
        spawnSmallWave(playerPos)
        smallWaveTimer_ = waveCfg.SmallInterval * intervalMult
    end

    -- 大波计时（60秒 × 难度间隔倍率）
    bigWaveTimer_ = bigWaveTimer_ - dt
    if bigWaveTimer_ <= 0 then
        spawnBigWave(playerPos)
        bigWaveTimer_ = waveCfg.BigInterval * intervalMult
    end

    -- 怪物升级计时（180秒）
    upgradeTimer_ = upgradeTimer_ - dt
    if upgradeTimer_ <= 0 then
        upgradeMonsters()
        upgradeTimer_ = waveCfg.MonsterUpgrade
    end

    -- Boss 计时（600秒）
    bossTimer_ = bossTimer_ - dt
    if bossTimer_ <= 0 then
        spawnTimedBoss(playerPos)
        bossTimer_ = waveCfg.BossInterval
    end

    -- 终极Boss 计时（1200秒=20分钟）
    ultimateBossTimer_ = ultimateBossTimer_ - dt
    if ultimateBossTimer_ <= 0 then
        EnemyManager.SpawnUltimateBoss(playerPos)
        ultimateBossTimer_ = 1200  -- 重置20分钟
    end

    for id, e in pairs(enemies_) do
        -- 冻结检测
        if e.freezeTimer > 0 then
            e.freezeTimer = e.freezeTimer - dt
            if e.freezeTimer <= 0 then
                -- 解冻：恢复原色
                setBodyFlash(e, false)
            end
        else
            -- 击退处理：击退期间跳过 AI 移动，只执行击退位移 + 动画
            if e.knockbackTimer and e.knockbackTimer > 0 then
                e.knockbackTimer = e.knockbackTimer - dt
                local kbCfg = GameConfig.Knockback
                -- 指数衰减
                local decay = math.exp(-kbCfg.DecayRate * dt)
                e.knockbackVel = e.knockbackVel * decay
                -- 计算新位置（使用 spawnPos.y 而非 pos.y 做 fallback，防止飞天累积）
                local pos = e.node.position
                local offset = e.knockbackVel * dt
                local safeY = e.spawnPos and e.spawnPos.y or pos.y
                local np = Vector3(pos.x + offset.x, pos.y, pos.z + offset.z)
                np.y = getGroundY(np.x, np.z, safeY)
                if not isBlockedByBuilding(pos, np) then
                    e.node.position = np
                else
                    -- 撞墙停止击退
                    e.knockbackTimer = 0
                    e.knockbackVel = nil
                end
                -- 速度过低则停止
                local vel = e.knockbackVel
                local kbStopped = false
                if vel and math.sqrt(vel.x * vel.x + vel.z * vel.z) < kbCfg.MinVelocity then
                    e.knockbackTimer = 0
                    e.knockbackVel = nil
                    kbStopped = true
                end

                -- ── 击退动画：倾斜 ──
                if e.kbDir and e.kbTiltTarget then
                    -- 平滑过渡到目标倾斜角
                    local tiltSpeed = 200  -- 度/秒
                    if e.kbTiltAngle < e.kbTiltTarget then
                        e.kbTiltAngle = math.min(e.kbTiltAngle + tiltSpeed * dt, e.kbTiltTarget)
                    end
                    -- 朝向击退方向 + 后仰倾斜
                    local yawAngle = math.atan(e.kbDir.x, e.kbDir.z) * 180 / math.pi
                    local yawRot = Quaternion(yawAngle, Vector3.UP)
                    local tiltRot = Quaternion(-e.kbTiltAngle, Vector3.RIGHT)  -- 本地空间向后仰
                    e.node.rotation = yawRot * tiltRot
                end

                -- ── 击退动画：缩放挤压/拉伸 ──
                if e.kbSquashTimer and e.kbSquashTimer > 0 then
                    -- 受击瞬间压扁（X/Z 扩大，Y 缩小）
                    e.kbSquashTimer = e.kbSquashTimer - dt
                    local t = math.max(0, e.kbSquashTimer / 0.1)  -- 1→0
                    local orig = e.kbOrigScale or Vector3(1, 1, 1)
                    local squashY = orig.y * (1.0 - 0.25 * t)   -- 最矮 0.75x
                    local squashXZ = orig.x * (1.0 + 0.15 * t)  -- 最宽 1.15x
                    e.node.scale = Vector3(squashXZ, squashY, squashXZ)
                elseif e.knockbackTimer and e.knockbackTimer > 0 then
                    -- 击退飞行中微拉伸
                    local orig = e.kbOrigScale or Vector3(1, 1, 1)
                    local stretchFactor = 0.08
                    e.node.scale = Vector3(orig.x * (1.0 - stretchFactor), orig.y * (1.0 + stretchFactor), orig.z * (1.0 - stretchFactor))
                end

                -- ── 击退结束：恢复姿态 ──
                if kbStopped or (e.knockbackTimer and e.knockbackTimer <= 0) then
                    e.kbRecoverTimer = 0.2  -- 恢复动画持续 0.2 秒
                    e.kbRecoverTilt = e.kbTiltAngle or 0
                    e.kbDir = nil
                    e.kbTiltAngle = nil
                    e.kbTiltTarget = nil
                    e.kbSquashTimer = nil
                    -- 缩放立即恢复
                    if e.kbOrigScale then
                        e.node.scale = e.kbOrigScale
                        e.kbOrigScale = nil
                    end
                end
            else
                -- ── 击退恢复动画：平滑回正 ──
                if e.kbRecoverTimer and e.kbRecoverTimer > 0 then
                    e.kbRecoverTimer = e.kbRecoverTimer - dt
                    local t = math.max(0, e.kbRecoverTimer / 0.2)  -- 1→0
                    local recoverTilt = (e.kbRecoverTilt or 0) * t
                    if recoverTilt > 0.5 then
                        -- 保持当前 yaw，只调整倾斜角
                        local curRot = e.node.rotation
                        -- 提取 yaw（直接用当前 rotation 中的 yaw 分量）
                        local euler = curRot:EulerAngles()
                        local yawRot = Quaternion(euler.y, Vector3.UP)
                        local tiltRot = Quaternion(-recoverTilt, Vector3.RIGHT)
                        e.node.rotation = yawRot * tiltRot
                    else
                        -- 倾斜角很小了，直接恢复为纯 yaw
                        e.kbRecoverTimer = 0
                    end
                    if e.kbRecoverTimer <= 0 then
                        e.kbRecoverTilt = nil
                        e.kbRecoverTimer = nil
                        -- faceToward 会在下帧 AI 中恢复正确朝向
                    end
                end
                -- 正常 AI（根据 aiType 分发）
                if e.aiType == "ultimate" then
                    updateUltimateBossAI(e, dt, playerPos)
                elseif e.aiType == "dragon" then
                    updateDragonAI(e, dt, playerPos)
                elseif e.aiType == "eliteAOE" then
                    updateEliteAOEAI(e, dt, playerPos)
                elseif e.aiType == "eliteDebuff" then
                    updateEliteDebuffAI(e, dt, playerPos)
                elseif e.aiType == "ranged" then
                    updateRangedAI(e, dt, playerPos)
                else
                    updateMeleeAI(e, dt, playerPos)
                end
            end
        end
        -- DOT: 减速计时
        if e.slowTimer and e.slowTimer > 0 then
            e.slowTimer = e.slowTimer - dt
        end
        -- DOT: 灼烧持续伤害
        if e.burnTimer and e.burnTimer > 0 then
            e.burnTimer = e.burnTimer - dt
            if e.burnDPS and e.burnDPS > 0 then
                e.hp = e.hp - e.burnDPS * dt
                if e.hp <= 0 then
                    -- 灼烧致死
                    e.hp = 0
                    local pos = e.node.position
                    -- 经验球（与正常击杀一致）
                    local cfg = GameConfig.Leveling
                    local orbCount
                    if e.isBoss then
                        orbCount = cfg.OrbsBoss
                    elseif e.type == "eliteMelee" or e.type == "eliteRanged"
                        or e.type == "eliteAOE" or e.type == "eliteDebuff" then
                        orbCount = math.floor(cfg.OrbsNormal * 2)
                    else
                        orbCount = cfg.OrbsNormal
                    end
                    orbCount = math.max(1, math.floor(orbCount * DifficultySystem.GetXPMult()))
                    XPOrbManager.SpawnOrbs(pos, orbCount, e.monsterLvl or 1)
                    killCount_ = killCount_ + 1
                    -- 灼烧致死货币奖励
                    applyKillReward(e)
                    -- Boss 击败回调检查
                    if id == activeBossId_ then
                        activeBossId_ = nil
                        if onBossDefeated_ then onBossDefeated_(e.monsterLvl or 1) end
                    end
                    if id == activeDragonId_ then
                        activeDragonId_ = nil
                        if onDragonDefeated_ then onDragonDefeated_(e.monsterLvl or 1) end
                    end
                    if id == activeUltimateBossId_ then
                        activeUltimateBossId_ = nil
                        if onUltimateDefeated_ then onUltimateDefeated_(e.monsterLvl or 1) end
                    end
                    -- 敌人死亡回调（掉落系统）
                    if onEnemyDeath_ then
                        onEnemyDeath_(e, e.node.position)
                    end
                    AudioManager.PlayEnemyDeath()
                    e.node:Remove()
                    enemies_[id] = nil
                    goto continue_enemy
                end
            end
        end
        -- 闪白恢复
        if e.flashTimer > 0 then
            e.flashTimer = e.flashTimer - dt
            if e.flashTimer <= 0 then
                if e.freezeTimer > 0 then
                    -- 仍然冻结 → 恢复冰蓝色
                    local bodyNode = e.node:GetChild("Body")
                    if bodyNode then
                        local mdl = bodyNode:GetComponent("StaticModel")
                        if mdl then mdl:SetMaterial(makeMat(Color(0.3, 0.5, 0.9, 1.0))) end
                    end
                else
                    setBodyFlash(e, false)
                end
            end
        end
        -- 风遁觉醒悬浮物理：持续悬浮 + 计时 + 自动坠落
        if e.liftTimer and e.liftTimer > 0 then
            e.liftTimer = e.liftTimer - dt
            -- 平滑上升到目标高度
            local pos = e.node.position
            local targetY = e.liftTarget or (pos.y + 10)
            if pos.y < targetY then
                local liftSpeed = 8.0  -- 上升速度 m/s
                local newY = math.min(pos.y + liftSpeed * dt, targetY)
                e.node.position = Vector3(pos.x, newY, pos.z)
            end
            -- 计时结束 → 进入坠落
            if e.liftTimer <= 0 then
                e.airborneVelY = 0
                e.airborneGroundY = e.liftGroundY or 0
                e.airborneFallDmg = e.liftFallDmg or 80
                e.liftTarget = nil
                e.liftDuration = nil
                e.liftCenter = nil
                e.liftRadius = nil
                e.liftGroundY = nil
                e.liftFallDmg = nil
                -- 恢复材质
                local bodyNode = e.node:GetChild("Body")
                if bodyNode then
                    local mdl = bodyNode:GetComponent("StaticModel")
                    if mdl then mdl:SetMaterial(makeMat(e.origColor or Color(1,1,1,1))) end
                end
            end
        end
        -- 风遁击飞物理：抛物线升降 + 落地伤害
        if e.airborneVelY then
            local gravity = 9.81
            e.airborneVelY = e.airborneVelY - gravity * dt
            local pos = e.node.position
            local newY = pos.y + e.airborneVelY * dt
            -- 落地检测
            if e.airborneVelY < 0 and newY <= (e.airborneGroundY or 0) then
                newY = e.airborneGroundY or 0
                -- 造成坠落伤害
                if e.airborneFallDmg and e.airborneFallDmg > 0 then
                    EnemyManager.DamageEnemy(id, e.airborneFallDmg)
                end
                e.airborneVelY = nil
                e.airborneGroundY = nil
                e.airborneFallDmg = nil
            end
            e.node.position = Vector3(pos.x, newY, pos.z)
        end
        -- 安全网：Y 边界钳制，防止飞天
        -- 跳过：悬浮状态、空中状态、龙Boss（飞行AI自行控制高度）
        if not e.airborneVelY
            and not (e.liftTimer and e.liftTimer > 0)
            and e.type ~= "dragonBoss"
        then
            clampEnemyY(e)
        end
        ::continue_enemy::
    end

    updateProjectiles(dt, playerPos)
    updateHitParticles(dt)
    EnemyManager.UpdateHealthPacks(dt, playerPos)
end

function EnemyManager.Reset()
    for _, e in pairs(enemies_) do
        if e.node then e.node:Remove() end
    end
    enemies_ = {}
    for _, p in ipairs(projectiles_) do
        if p.node then p.node:Remove() end
    end
    projectiles_ = {}
    for _, hp in pairs(healthPacks_) do
        if hp.node then hp.node:Remove() end
    end
    healthPacks_ = {}
    -- 清理命中粒子
    for _, p in ipairs(hitParticles_) do
        if p.node then p.node:Remove() end
    end
    hitParticles_ = {}
    hitParticleMats_ = nil
    -- 清空材质缓存
    clearMatCache()
    -- 清空 GetAllEnemies 帧缓存
    allEnemiesCache_ = nil
    allEnemiesCacheFrame_ = -1
    nextHPId_ = 1
    nextId_ = 1

    -- 重置波次状态（四计时器 + 怪物等级）
    local waveCfg = GameConfig.Enemies.Wave
    smallWaveTimer_ = waveCfg.SmallInterval
    bigWaveTimer_   = waveCfg.BigInterval
    upgradeTimer_   = waveCfg.MonsterUpgrade
    bossTimer_      = waveCfg.BossInterval
    waveNumber_ = 0
    bossCount_ = 0
    monsterLevel_ = 1
    activeBossId_ = nil
    activeDragonId_ = nil
    activeUltimateBossId_ = nil
    ultimateBossTimer_ = 1200  -- 20分钟
    gameElapsed_ = 0

    -- 立即生成第一小波
    spawnSmallWave(playerGetPos_())
    print("[EnemyManager] 敌人已重置，时间驱动刷怪重新开始")
end

-- ============================================================================
-- 血包掉落系统
-- ============================================================================

--- 在指定位置生成一个血包
---@param pos Vector3
function EnemyManager.SpawnHealthPack(pos)
    if not scene_ then return end
    local id = nextHPId_
    nextHPId_ = nextHPId_ + 1

    local node = scene_:CreateChild("HealthPack_" .. id)
    node.position = Vector3(pos.x, pos.y + 0.4, pos.z)

    -- 十字形血包模型（红色发光球）
    local mdl = node:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    local mat = GameConfig.CreateEmissiveMaterial(Color(1.0, 0.2, 0.2, 1.0), 4.0)
    mdl:SetMaterial(mat)
    node.scale = Vector3(0.2, 0.2, 0.2)

    -- 红色点光源
    local pl = node:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = 3.0
    pl.color = Color(1.0, 0.3, 0.3, 1.0)
    pl.brightness = 2.0

    healthPacks_[id] = {
        id = id,
        node = node,
        life = GameConfig.Leveling.HealthDropLife,
        phase = math.random() * 6.28,
    }
end

--- 每帧更新血包（悬浮动画 + 拾取检测）
---@param dt number
---@param playerPos Vector3
function EnemyManager.UpdateHealthPacks(dt, playerPos)
    if not playerPos then return end
    local cfg = GameConfig.Leveling
    local toRemove = {}

    for id, hp in pairs(healthPacks_) do
        hp.life = hp.life - dt
        if hp.life <= 0 then
            table.insert(toRemove, id)
        else
            local pos = hp.node.position
            -- 悬浮动画
            hp.phase = hp.phase + dt * 3.0
            hp.node.position = Vector3(pos.x, 0.4 + math.sin(hp.phase) * 0.15, pos.z)
            -- 旋转
            hp.node.rotation = hp.node.rotation * Quaternion(dt * 120, Vector3.UP)

            -- 拾取检测
            local dx = playerPos.x - pos.x
            local dz = playerPos.z - pos.z
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist < cfg.HealthCollectDist then
                PlayerHealth.Heal(cfg.HealthDropHeal)
                AudioManager.PlayItemPickup()
                table.insert(toRemove, id)
            end
        end
    end

    for _, id in ipairs(toRemove) do
        local hp = healthPacks_[id]
        if hp and hp.node then hp.node:Remove() end
        healthPacks_[id] = nil
    end
end

return EnemyManager
