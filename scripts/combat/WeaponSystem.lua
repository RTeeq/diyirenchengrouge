-- ============================================================================
-- WeaponSystem.lua — 武器系统
-- Q/E 切换左手武器，滚轮切换左手道具/技能
-- ============================================================================

local GameConfig = require("config.GameConfig")
local GameManager = require("core.GameManager")
local EnemyManager = require("combat.EnemyManager")
local PlayerHealth = require("combat.PlayerHealth")
local LevelSystem = require("combat.LevelSystem")
local AudioManager = require("core.AudioManager")
local EquipmentSystem = require("combat.EquipmentSystem")
local SkillSystem = require("combat.SkillSystem")
local KillBonusSystem = require("combat.KillBonusSystem")
local MeleeWeaponView = require("combat.MeleeWeaponView")
local MagicWeaponView = require("combat.MagicWeaponView")
local MobileControls = require("ui.MobileControls")
local GamepadControls = require("ui.GamepadControls")
local AwakeningSystem = require("systems.AwakeningSystem")

local WeaponSystem = {}

---@type Scene
local scene_ = nil
local getPlayerPos_ = nil
local getCameraNode_ = nil

local availableWeapons_ = {}   -- 已收集武器 ID 列表（有序），iron_sword 始终在首位
local currentIndex_ = 1        -- 1=铁剑（默认基础武器）, 2+=其他武器
local cooldowns_ = {}          -- { [itemId] = remaining }
local activeEffects_ = {}      -- 活跃特效
local onWeaponChanged_ = nil   -- 切换回调
local currentSkillSlot_ = 0    -- 0=非技能模式, 1-6=技能槽位

-- 双手武器系统：右手始终持剑（右键），左手持可切换道具/技能（左键）
local leftHandIndex_ = 1       -- 左手道具在 leftHandList_ 中的索引
local leftHandList_ = {}       -- 左手可用列表：武器(非iron_sword) + 已解锁技能

-- 技能顺序引用（与 SkillSystem 一致）
local SKILL_ORDER_REF = { "shockwave", "timeFreeze", "lightningStorm", "fireStorm", "voidPull", "healAura" }

--- 构建左手切换列表：武器(非iron_sword) + 已解锁技能
local function buildLeftHandList()
    local list = {}
    for i, wid in ipairs(availableWeapons_) do
        if wid ~= "iron_sword" then
            table.insert(list, { type = "weapon", weaponIndex = i, id = wid })
        end
    end
    for si = 1, #SKILL_ORDER_REF do
        if LevelSystem.HasSkill(SKILL_ORDER_REF[si]) then
            table.insert(list, { type = "skill", slotIndex = si, id = SKILL_ORDER_REF[si] })
        end
    end
    return list
end

--- 应用左手槽位
local function applyLeftHandSlot(slot)
    if slot.type == "weapon" then
        currentIndex_ = slot.weaponIndex
        currentSkillSlot_ = 0
    elseif slot.type == "skill" then
        currentSkillSlot_ = slot.slotIndex
    end
    -- 更新左手武器模型
    WeaponSystem.UpdateWeaponVisibility()
    if onWeaponChanged_ then onWeaponChanged_() end
end

-- ============================================================================
-- 工具
-- ============================================================================

local function distXZ(a, b)
    local dx, dz = a.x - b.x, a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end

local function makeGlow(color, intensity)
    return GameConfig.CreateEmissiveMaterial(color, intensity or 2.0)
end

local function getCamPosDir()
    local cam = getCameraNode_()
    return cam.worldPosition, cam.worldRotation * Vector3.FORWARD
end

--- 创建一个短暂闪光球
local function createFlash(pos, color, duration)
    local n = scene_:CreateChild("Flash")
    n.position = pos
    local mdl = n:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    mdl:SetMaterial(makeGlow(color, 5.0))
    n.scale = Vector3(0.4, 0.4, 0.4)
    local pl = n:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = 5.0
    pl.color = color
    pl.brightness = 3.0
    table.insert(activeEffects_, { type = "flash", node = n, life = duration or 0.2 })
end

-- ============================================================================
-- 武器攻击实现
-- ============================================================================



local ATTACKS = {}

-- 1. 火龙牌 — 火球术：发射火球，命中爆炸
---@param dirOverride Vector3|nil 可选方向覆盖（扩散弹体用）
ATTACKS["fire_dragon_card"] = function(dirOverride)
    local cfg = GameConfig.Weapons.fire_dragon_card
    local camPos, camDir = getCamPosDir()
    local fireDir = dirOverride or camDir
    local startPos = camPos + fireDir * 0.8

    local sizeMult = LevelSystem.GetAttackSizeMult()
    local fbScale = 0.25 * sizeMult

    local node = scene_:CreateChild("Fireball")
    node.position = startPos
    local mdl = node:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    mdl:SetMaterial(makeGlow(cfg.color, 4.0))
    node.scale = Vector3(fbScale, fbScale, fbScale)
    local pl = node:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = 6.0
    pl.color = cfg.color
    pl.brightness = 2.5

    EquipmentSystem.ApplyOverlayToNode(node)
    table.insert(activeEffects_, {
        type = "fireball", node = node, dir = fireDir,
        speed = cfg.speed, damage = cfg.damage,
        splashDamage = cfg.splashDamage, splashRange = cfg.splashRange * sizeMult,
        hitRadius = 1.0 * sizeMult,
        life = 3.0,
    })
end

-- 2. 平安玉 — 护盾：3 秒无敌
ATTACKS["peace_jade"] = function()
    local cfg = GameConfig.Weapons.peace_jade
    local playerPos = getPlayerPos_()

    PlayerHealth.SetShielded(true)

    local node = scene_:CreateChild("Shield")
    node.position = playerPos
    local mdl = node:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    mdl:SetMaterial(GameConfig.CreateAlphaMaterial(
        Color(cfg.color.r, cfg.color.g, cfg.color.b, 0.25)))
    node.scale = Vector3(2.0, 2.0, 2.0)
    local pl = node:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = 4.0
    pl.color = cfg.color
    pl.brightness = 1.0

    table.insert(activeEffects_, {
        type = "shield", node = node, life = cfg.duration,
    })
end

-- 3. 密钥 — 穿刺：穿透直线上所有敌人
ATTACKS["secret_key"] = function()
    local cfg = GameConfig.Weapons.secret_key
    local camPos, camDir = getCamPosDir()
    local sizeMult = LevelSystem.GetAttackSizeMult()
    local dotMin = cfg.dotMin / sizeMult
    local hits = EnemyManager.PierceAttack(camPos, camDir, cfg.range, dotMin, cfg.damage)
    -- 穿刺光线视觉
    local endPos = camPos + camDir * cfg.range
    createFlash(camPos + camDir * (cfg.range * 0.5), cfg.color, 0.15)
    if hits > 0 then
        createFlash(camPos + camDir * 2.0, Color(1, 1, 0.5), 0.2)

    end
end

-- 4. 八卦镜 — 破魔光线：远程高伤单体
ATTACKS["bagua_mirror"] = function()
    local cfg = GameConfig.Weapons.bagua_mirror
    local camPos, camDir = getCamPosDir()
    local sizeMult = LevelSystem.GetAttackSizeMult()
    local dotMin = cfg.dotMin / sizeMult
    local hit = EnemyManager.ConeAttack(camPos, camDir, cfg.range, dotMin, cfg.damage)
    -- 光线闪光
    createFlash(camPos + camDir * 1.5, cfg.color, 0.25)
    if hit then
        createFlash(camPos + camDir * 4.0, Color(1, 0.8, 1), 0.3)
    end
end

-- 5. 驱邪符 — 追踪符：自动追踪最近敌人
---@param dirOverride Vector3|nil 可选方向覆盖（扩散弹体用）
ATTACKS["exorcism_talisman"] = function(dirOverride)
    local cfg = GameConfig.Weapons.exorcism_talisman
    local camPos, camDir = getCamPosDir()
    local fireDir = dirOverride or camDir
    local startPos = camPos + fireDir * 0.8

    local node = scene_:CreateChild("HomingTalisman")
    node.position = startPos
    local mdl = node:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    mdl:SetMaterial(makeGlow(cfg.color, 3.0))
    node.scale = Vector3(0.2, 0.3, 0.04)
    local pl = node:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = 3.0
    pl.color = cfg.color
    pl.brightness = 2.0

    local sizeMult = LevelSystem.GetAttackSizeMult()
    EquipmentSystem.ApplyOverlayToNode(node)
    table.insert(activeEffects_, {
        type = "homing", node = node, dir = fireDir,
        speed = cfg.speed, damage = cfg.damage, life = 4.0,
        hitRadius = 0.8 * sizeMult,
    })
end

-- 6. 神秘碎片 — 连锁闪电：跳跃命中多个敌人
ATTACKS["mystery_fragment"] = function()
    local cfg = GameConfig.Weapons.mystery_fragment
    local playerPos = getPlayerPos_()
    local sizeMult = LevelSystem.GetAttackSizeMult()

    local hitIds = {}
    local currentPos = playerPos
    local chains = 0
    local totalDmg = 0

    while chains < cfg.maxChains do
        local bestDist = (chains == 0) and (cfg.range * sizeMult) or (cfg.chainRange * sizeMult)
        local bestId = nil
        local bestE = nil
        for id, e in pairs(EnemyManager.GetAllEnemies()) do
            if not hitIds[id] then
                local d = distXZ(currentPos, e.node.position)
                if d < bestDist then
                    bestDist = d
                    bestId = id
                    bestE = e
                end
            end
        end
        if not bestId then break end
        EnemyManager.DamageEnemy(bestId, cfg.damage)
        EquipmentSystem.OnAttackHit(bestId, cfg.damage, bestE.node.position)
        totalDmg = totalDmg + cfg.damage
        hitIds[bestId] = true
        createFlash(bestE.node.position + Vector3(0, 0.8, 0), cfg.color, 0.25)
        currentPos = bestE.node.position
        chains = chains + 1
    end

    if chains > 0 then
        createFlash(playerPos + Vector3(0, 1.0, 0), cfg.color, 0.15)
    end
end

-- 7. 打开的密卷 — 旋风：持续范围伤害
ATTACKS["opened_scroll"] = function()
    local cfg = GameConfig.Weapons.opened_scroll
    local playerPos = getPlayerPos_()
    local sizeMult = LevelSystem.GetAttackSizeMult()

    -- 创建 4 个旋转块
    local nodes = {}
    for i = 1, 4 do
        local n = scene_:CreateChild("Whirlwind_" .. i)
        local mdl = n:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        mdl:SetMaterial(makeGlow(cfg.color, 2.0))
        n.scale = Vector3(0.12, 0.6, 0.12)
        table.insert(nodes, n)
    end

    table.insert(activeEffects_, {
        type = "whirlwind", nodes = nodes, angle = 0,
        life = cfg.duration, tickTimer = 0,
        tickInterval = cfg.tickInterval,
        tickDamage = cfg.tickDamage, range = cfg.range * sizeMult,
    })
end

-- 8. 被封印的密卷 — 封印术：冻结范围内敌人
ATTACKS["sealed_scroll"] = function()
    local cfg = GameConfig.Weapons.sealed_scroll
    local playerPos = getPlayerPos_()
    local sizeMult = LevelSystem.GetAttackSizeMult()
    EnemyManager.FreezeEnemies(playerPos, cfg.range * sizeMult, cfg.freezeDuration)
    -- 冰冻波视觉
    createFlash(playerPos + Vector3(0, 0.5, 0), cfg.color, 0.4)
end

-- 9. 密盒 — 陷阱：放置地雷
ATTACKS["secret_box"] = function()
    local cfg = GameConfig.Weapons.secret_box
    local playerPos = getPlayerPos_()
    local sizeMult = LevelSystem.GetAttackSizeMult()

    -- 限制最大数量
    local trapCount = 0
    local oldest = nil
    local oldestIdx = nil
    for i, fx in ipairs(activeEffects_) do
        if fx.type == "trap" and not fx.dead then
            trapCount = trapCount + 1
            if not oldest or fx.life < (oldest.life or 999) then
                oldest = fx
                oldestIdx = i
            end
        end
    end
    if trapCount >= cfg.maxTraps and oldest then
        oldest.dead = true
    end

    local node = scene_:CreateChild("Trap")
    node.position = Vector3(playerPos.x, playerPos.y - 0.5, playerPos.z)
    local mdl = node:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    mdl:SetMaterial(makeGlow(cfg.color, 1.5))
    node.scale = Vector3(0.3, 0.15, 0.3)
    local pl = node:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = 2.0
    pl.color = cfg.color
    pl.brightness = 0.8

    table.insert(activeEffects_, {
        type = "trap", node = node,
        damage = cfg.damage, triggerRange = cfg.triggerRange * sizeMult,
        life = 60.0,  -- 持续 60 秒
    })
end

-- 10. 圣水 — 净化：回血 + 范围圣伤
ATTACKS["holy_water"] = function()
    local cfg = GameConfig.Weapons.holy_water
    local playerPos = getPlayerPos_()
    local sizeMult = LevelSystem.GetAttackSizeMult()
    PlayerHealth.Heal(cfg.healAmount)
    EnemyManager.AOEDamage(playerPos, cfg.range * sizeMult, cfg.damage)
    -- 净化波视觉
    local node = scene_:CreateChild("Purify")
    node.position = playerPos
    local mdl = node:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    mdl:SetMaterial(GameConfig.CreateAlphaMaterial(
        Color(0.9, 0.9, 1.0, 0.3)))
    node.scale = Vector3(0.5, 0.5, 0.5)
    local pl = node:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = 8.0
    pl.color = Color(0.9, 0.9, 1.0)
    pl.brightness = 3.0
    table.insert(activeEffects_, {
        type = "purify", node = node, life = 0.6, startScale = 0.5, endScale = 12.0,
    })
end

-- 11. 雷鼓 — 雷霆冲击：以自身为中心AOE冲击波+击退
ATTACKS["thunder_drum"] = function()
    local cfg = GameConfig.Weapons.thunder_drum
    local playerPos = getPlayerPos_()
    local sizeMult = LevelSystem.GetAttackSizeMult()
    local range = cfg.range * sizeMult

    -- 对范围内所有敌人造成伤害并击退
    local _, camDir = getCamPosDir()
    for id, e in pairs(EnemyManager.GetAllEnemies()) do
        local d = distXZ(playerPos, e.node.position)
        if d < range then
            EnemyManager.DamageEnemy(id, cfg.damage)
            EquipmentSystem.OnAttackHit(id, cfg.damage, e.node.position)
            -- 从玩家向外击退
            local kbDir = (e.node.position - playerPos):Normalized()
            EnemyManager.ApplyKnockback(id, kbDir, cfg.knockbackForce)
        end
    end

    -- 冲击波视觉：扩展环
    local node = scene_:CreateChild("ThunderWave")
    node.position = playerPos
    local mdl = node:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    mdl:SetMaterial(GameConfig.CreateAlphaMaterial(
        Color(cfg.color.r, cfg.color.g, cfg.color.b, 0.4)))
    node.scale = Vector3(0.5, 0.1, 0.5)
    local pl = node:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = 8.0
    pl.color = cfg.glowColor
    pl.brightness = 4.0

    table.insert(activeEffects_, {
        type = "thunder_wave", node = node, life = 0.5,
        startScale = 0.5, endScale = range * 2,
    })
    AudioManager.PlayExplosion()
end

-- 12. 影扇 — 影分身：召唤影分身自动攻击附近敌人
ATTACKS["shadow_fan"] = function()
    local cfg = GameConfig.Weapons.shadow_fan
    local playerPos = getPlayerPos_()

    -- 清除旧分身（超过上限）
    local cloneCount = 0
    for _, fx in ipairs(activeEffects_) do
        if fx.type == "shadow_clone" and not fx.dead then
            cloneCount = cloneCount + 1
        end
    end
    if cloneCount >= cfg.maxClones then
        for _, fx in ipairs(activeEffects_) do
            if fx.type == "shadow_clone" and not fx.dead then
                fx.dead = true
                break
            end
        end
    end

    -- 生成分身
    local node = scene_:CreateChild("ShadowClone")
    local offset = Quaternion(math.random(0, 360), Vector3.UP) * Vector3(0, 0, 2)
    node.position = playerPos + offset
    -- 身体
    local body = node:CreateChild("Body")
    local mdl = body:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    mdl:SetMaterial(GameConfig.CreateAlphaMaterial(
        Color(cfg.color.r, cfg.color.g, cfg.color.b, 0.6)))
    body.scale = Vector3(0.5, 1.4, 0.3)
    body.position = Vector3(0, 0.7, 0)
    -- 头
    local head = node:CreateChild("Head")
    local hmdl = head:CreateComponent("StaticModel")
    hmdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    hmdl:SetMaterial(GameConfig.CreateAlphaMaterial(
        Color(cfg.glowColor.r, cfg.glowColor.g, cfg.glowColor.b, 0.5)))
    head.scale = Vector3(0.35, 0.35, 0.35)
    head.position = Vector3(0, 1.6, 0)

    table.insert(activeEffects_, {
        type = "shadow_clone", node = node,
        life = cfg.duration, attackTimer = 0,
        damage = cfg.damage, speed = cfg.cloneSpeed,
        range = cfg.cloneRange, attackCD = 1.0,
    })
end

-- 13. 血罗盘 — 血域：在玩家脚下创建持续伤害+减速区域
ATTACKS["blood_compass"] = function()
    local cfg = GameConfig.Weapons.blood_compass
    local playerPos = getPlayerPos_()
    local sizeMult = LevelSystem.GetAttackSizeMult()

    local node = scene_:CreateChild("BloodZone")
    node.position = Vector3(playerPos.x, playerPos.y - 0.4, playerPos.z)
    local mdl = node:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    mdl:SetMaterial(GameConfig.CreateAlphaMaterial(
        Color(cfg.color.r, cfg.color.g, cfg.color.b, 0.35)))
    local s = cfg.range * sizeMult
    node.scale = Vector3(s, 0.05, s)
    local pl = node:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = cfg.range
    pl.color = cfg.glowColor
    pl.brightness = 2.0

    table.insert(activeEffects_, {
        type = "blood_zone", node = node, life = cfg.duration,
        tickTimer = 0, tickInterval = cfg.tickInterval,
        tickDamage = cfg.tickDamage, range = cfg.range * sizeMult,
        slowPct = cfg.slowPct,
    })
end

-- 14. 翠笛 — 战歌：增益光环（攻速+移速）
ATTACKS["jade_flute"] = function()
    local cfg = GameConfig.Weapons.jade_flute
    local playerPos = getPlayerPos_()

    local node = scene_:CreateChild("BuffAura")
    node.position = playerPos
    local mdl = node:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    mdl:SetMaterial(GameConfig.CreateAlphaMaterial(
        Color(cfg.color.r, cfg.color.g, cfg.color.b, 0.2)))
    node.scale = Vector3(3.0, 3.0, 3.0)
    local pl = node:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = 6.0
    pl.color = cfg.glowColor
    pl.brightness = 2.0

    table.insert(activeEffects_, {
        type = "jade_buff", node = node, life = cfg.duration,
        atkSpdBonus = cfg.atkSpdBonus, moveSpdBonus = cfg.moveSpdBonus,
    })
end

-- 15. 灵铃 — 灵铃阵：环绕玩家的灵球，接触伤害
ATTACKS["spirit_bell"] = function()
    local cfg = GameConfig.Weapons.spirit_bell
    local playerPos = getPlayerPos_()

    local orbs = {}
    for i = 1, cfg.orbCount do
        local n = scene_:CreateChild("SpiritOrb_" .. i)
        local mdl = n:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        mdl:SetMaterial(makeGlow(cfg.glowColor, 3.0))
        n.scale = Vector3(0.25, 0.25, 0.25)
        local pl = n:CreateComponent("Light")
        pl.lightType = LIGHT_POINT
        pl.castShadows = false
        pl.range = 3.0
        pl.color = cfg.glowColor
        pl.brightness = 1.5
        table.insert(orbs, n)
    end

    table.insert(activeEffects_, {
        type = "spirit_orbs", nodes = orbs, angle = 0,
        life = cfg.duration, damage = cfg.damage,
        orbRadius = cfg.orbRadius, orbSpeed = cfg.orbSpeed,
        hitTimer = 0, hitInterval = 0.5,
    })
end

-- ============================================================================
-- 特效更新
-- ============================================================================

local function updateEffects(dt)
    local playerPos = getPlayerPos_()
    local toRemove = {}

    for i, fx in ipairs(activeEffects_) do
        if fx.dead then
            table.insert(toRemove, i)
        elseif fx.type == "flash" then
            fx.life = fx.life - dt
            if fx.life <= 0 then table.insert(toRemove, i) end

        elseif fx.type == "fireball" then
            fx.life = fx.life - dt
            if fx.life <= 0 then
                table.insert(toRemove, i)
            else
                fx.node.position = fx.node.position + fx.dir * fx.speed * dt
                -- 检测命中敌人
                local pos = fx.node.position
                local hr = fx.hitRadius or 1.0
                for id, e in pairs(EnemyManager.GetAllEnemies()) do
                    if (e.node.position + Vector3(0, 0.7, 0) - pos):Length() < hr then
                        -- 直接命中
                        EnemyManager.DamageEnemy(id, fx.damage)
                        EquipmentSystem.OnAttackHit(id, fx.damage, pos)
                        -- 爆炸 AOE
                        EnemyManager.AOEDamage(pos, fx.splashRange, fx.splashDamage)
                        createFlash(pos, Color(1, 0.5, 0.1), 0.3)
                        AudioManager.PlayExplosion()
                        fx.dead = true
                        break
                    end
                end
            end

        elseif fx.type == "shield" then
            fx.life = fx.life - dt
            fx.node.position = playerPos
            if fx.life <= 0 then
                PlayerHealth.SetShielded(false)
                table.insert(toRemove, i)
            end

        elseif fx.type == "homing" then
            fx.life = fx.life - dt
            if fx.life <= 0 then
                table.insert(toRemove, i)
            else
                -- 追踪最近敌人
                local nearId, nearE = EnemyManager.GetNearestEnemy(fx.node.position, 20.0)
                if nearE then
                    local target = nearE.node.position + Vector3(0, 0.8, 0)
                    local toTarget = (target - fx.node.position):Normalized()
                    -- 平滑转向
                    fx.dir = (fx.dir + toTarget * dt * 5.0):Normalized()
                end
                fx.node.position = fx.node.position + fx.dir * fx.speed * dt
                fx.node.rotation = fx.node.rotation * Quaternion(dt * 720, Vector3.UP)
                -- 命中检测
                local hr = fx.hitRadius or 0.8
                for id, e in pairs(EnemyManager.GetAllEnemies()) do
                    if (e.node.position + Vector3(0, 0.7, 0) - fx.node.position):Length() < hr then
                        EnemyManager.DamageEnemy(id, fx.damage)
                        EquipmentSystem.OnAttackHit(id, fx.damage, fx.node.position)
                        createFlash(fx.node.position, Color(0.9, 0.8, 0.2), 0.2)
                        fx.dead = true
                        break
                    end
                end
            end

        elseif fx.type == "whirlwind" then
            fx.life = fx.life - dt
            if fx.life <= 0 then
                table.insert(toRemove, i)
            else
                fx.angle = fx.angle + dt * 400
                for j, n in ipairs(fx.nodes) do
                    local a = math.rad(fx.angle + (j - 1) * 90)
                    local r = 1.5
                    n.position = Vector3(
                        playerPos.x + math.cos(a) * r,
                        playerPos.y + 0.3,
                        playerPos.z + math.sin(a) * r
                    )
                    n.rotation = Quaternion(fx.angle + j * 90, Vector3.UP)
                end
                -- 周期伤害
                fx.tickTimer = fx.tickTimer + dt
                if fx.tickTimer >= fx.tickInterval then
                    fx.tickTimer = fx.tickTimer - fx.tickInterval
                    EnemyManager.AOEDamage(playerPos, fx.range, fx.tickDamage)
                end
            end

        elseif fx.type == "trap" then
            fx.life = fx.life - dt
            if fx.life <= 0 then
                table.insert(toRemove, i)
            else
                -- 检测敌人接近
                for id, e in pairs(EnemyManager.GetAllEnemies()) do
                    if distXZ(fx.node.position, e.node.position) < fx.triggerRange then
                        EnemyManager.AOEDamage(fx.node.position, fx.triggerRange + 1.0, fx.damage)
                        createFlash(fx.node.position + Vector3(0, 0.5, 0), Color(1, 0.4, 0.1), 0.35)
                        AudioManager.PlayTrapTrigger()
                        fx.dead = true
                        break
                    end
                end
            end

        elseif fx.type == "purify" then
            fx.life = fx.life - dt
            if fx.life <= 0 then
                table.insert(toRemove, i)
            else
                -- 膨胀效果
                local pct = 1.0 - fx.life / 0.6
                local s = fx.startScale + (fx.endScale - fx.startScale) * pct
                fx.node.scale = Vector3(s, s, s)
                fx.node.position = playerPos
            end

        elseif fx.type == "thunder_wave" then
            fx.life = fx.life - dt
            if fx.life <= 0 then
                table.insert(toRemove, i)
            else
                local pct = 1.0 - fx.life / 0.5
                local s = fx.startScale + (fx.endScale - fx.startScale) * pct
                fx.node.scale = Vector3(s, 0.1, s)
                fx.node.position = playerPos
            end

        elseif fx.type == "shadow_clone" then
            fx.life = fx.life - dt
            if fx.life <= 0 then
                table.insert(toRemove, i)
            else
                -- 分身追踪并攻击最近敌人
                local nearId, nearE = EnemyManager.GetNearestEnemy(fx.node.position, fx.range)
                if nearE then
                    local target = nearE.node.position
                    local toTarget = (target - fx.node.position):Normalized()
                    fx.node.position = fx.node.position + toTarget * fx.speed * dt
                    -- 面朝目标
                    fx.node.rotation = Quaternion(0, Vector3.UP)
                    -- 攻击
                    fx.attackTimer = fx.attackTimer + dt
                    if fx.attackTimer >= fx.attackCD then
                        fx.attackTimer = 0
                        local d = distXZ(fx.node.position, target)
                        if d < 2.0 then
                            EnemyManager.DamageEnemy(nearId, fx.damage)
                            EquipmentSystem.OnAttackHit(nearId, fx.damage, target)
                            createFlash(target + Vector3(0, 0.8, 0), Color(0.5, 0.2, 0.8), 0.15)
                        end
                    end
                else
                    -- 没有敌人时跟随玩家
                    local toPlayer = (playerPos - fx.node.position):Normalized()
                    local dPlayer = distXZ(fx.node.position, playerPos)
                    if dPlayer > 3.0 then
                        fx.node.position = fx.node.position + toPlayer * fx.speed * dt
                    end
                end
            end

        elseif fx.type == "blood_zone" then
            fx.life = fx.life - dt
            if fx.life <= 0 then
                table.insert(toRemove, i)
            else
                -- 周期伤害 + 减速
                fx.tickTimer = fx.tickTimer + dt
                if fx.tickTimer >= fx.tickInterval then
                    fx.tickTimer = fx.tickTimer - fx.tickInterval
                    local zonePos = fx.node.position
                    for id, e in pairs(EnemyManager.GetAllEnemies()) do
                        if distXZ(zonePos, e.node.position) < fx.range then
                            EnemyManager.DamageEnemy(id, fx.tickDamage)
                            -- 减速效果
                            if fx.slowPct and fx.slowPct > 0 then
                                EnemyManager.ApplySlow(id, fx.tickInterval + 0.2)
                            end
                        end
                    end
                end
                -- 视觉脉动
                local pulse = 1.0 + math.sin(fx.life * 4) * 0.05
                local baseS = fx.range
                fx.node.scale = Vector3(baseS * pulse, 0.05, baseS * pulse)
            end

        elseif fx.type == "jade_buff" then
            fx.life = fx.life - dt
            if fx.life <= 0 then
                table.insert(toRemove, i)
            else
                fx.node.position = playerPos
                -- 呼吸动画
                local pulse = 3.0 + math.sin(fx.life * 3) * 0.3
                fx.node.scale = Vector3(pulse, pulse, pulse)
            end

        elseif fx.type == "spirit_orbs" then
            fx.life = fx.life - dt
            if fx.life <= 0 then
                table.insert(toRemove, i)
            else
                fx.angle = fx.angle + fx.orbSpeed * dt
                local count = #fx.nodes
                for j, n in ipairs(fx.nodes) do
                    local a = math.rad(fx.angle + (j - 1) * (360 / count))
                    n.position = Vector3(
                        playerPos.x + math.cos(a) * fx.orbRadius,
                        playerPos.y + 1.0,
                        playerPos.z + math.sin(a) * fx.orbRadius
                    )
                end
                -- 接触伤害
                fx.hitTimer = fx.hitTimer + dt
                if fx.hitTimer >= fx.hitInterval then
                    fx.hitTimer = fx.hitTimer - fx.hitInterval
                    for _, n in ipairs(fx.nodes) do
                        for id, e in pairs(EnemyManager.GetAllEnemies()) do
                            if (e.node.position + Vector3(0, 0.7, 0) - n.position):Length() < 1.0 then
                                EnemyManager.DamageEnemy(id, fx.damage)
                                EquipmentSystem.OnAttackHit(id, fx.damage, n.position)
                            end
                        end
                    end
                end
            end

        elseif fx.type == "sweep_ice" or fx.type == "sweep_fire" then
            fx.life = fx.life - dt
            if fx.life <= 0 then
                table.insert(toRemove, i)
            else
                -- 脉动透明度
                local pulse = 0.20 + math.sin(fx.life * 5) * 0.06
                local alpha = pulse
                -- 最后 1 秒渐隐
                if fx.life < 1.0 then alpha = alpha * fx.life end
                local bc = fx.baseColor
                local mat = GameConfig.CreateAlphaMaterial(Color(bc.r, bc.g, bc.b, alpha))
                mat:SetShaderParameter("MatEmissiveColor", Variant(fx.emissiveColor))
                local mdl = fx.node:GetComponent("StaticModel")
                if mdl then mdl:SetMaterial(mat) end

                -- 光照衰减
                local pl = fx.node:GetComponent("Light")
                if pl then
                    local bright = 3.0
                    if fx.life < 1.0 then bright = bright * fx.life end
                    pl.brightness = bright
                end

                -- 随机砍击闪光
                fx.flashTimer = fx.flashTimer + dt
                if fx.flashTimer >= 0.3 then
                    fx.flashTimer = 0
                    local randAngle = math.rad(math.random(-90, 90))
                    local yawRad = math.rad(math.deg(math.atan(fx.forward.x, fx.forward.z)))
                    local wa = yawRad + randAngle
                    local randR = math.random() * fx.radius * 0.9
                    local flashPos = fx.origin + Vector3(
                        math.sin(wa) * randR, 0.2, math.cos(wa) * randR)
                    local flashNode = scene_:CreateChild("SweepFlash")
                    flashNode.position = flashPos
                    local fMdl = flashNode:CreateComponent("StaticModel")
                    fMdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
                    local fc = fx.baseColor
                    fMdl:SetMaterial(makeGlow(Color(fc.r * 2, fc.g * 2, fc.b * 2, 1.0), 4.0))
                    flashNode.scale = Vector3(0.4, 0.12, 0.4)
                    flashNode.rotation = Quaternion(math.random(0, 360), Vector3.UP)
                    table.insert(fx.flashNodes, { node = flashNode, life = 0.2 })
                end
                -- 更新闪光生命期
                for j = #fx.flashNodes, 1, -1 do
                    local sf = fx.flashNodes[j]
                    sf.life = sf.life - dt
                    if sf.life <= 0 then
                        sf.node:Remove()
                        table.remove(fx.flashNodes, j)
                    else
                        local s = sf.life / 0.2
                        sf.node.scale = Vector3(0.4 * s, 0.12 * s, 0.4 * s)
                    end
                end
            end

        elseif fx.type == "wind_release" then
            fx.life = fx.life - dt
            if fx.life <= 0 then
                table.insert(toRemove, i)
            else
                -- 旋转风柱
                fx.spinAngle = fx.spinAngle + dt * 180
                local r = fx.radius * 0.7
                for j, pNode in ipairs(fx.pillarNodes) do
                    local baseA = (j - 1) * 45
                    local a = math.rad(baseA + fx.spinAngle)
                    pNode.position = fx.origin + Vector3(
                        math.sin(a) * r, 0.5, math.cos(a) * r)
                    pNode.rotation = Quaternion(baseA + fx.spinAngle, Vector3.UP)
                    -- 高度脉动
                    local hPulse = 2.0 + math.sin(fx.life * 4 + j) * 0.5
                    pNode.scale = Vector3(0.08, hPulse, 0.08)
                end

                -- 主体透明度渐隐
                local alpha = 0.15
                if fx.life < 1.0 then alpha = alpha * fx.life end
                local mat = GameConfig.CreateAlphaMaterial(Color(0.3, 0.9, 0.4, alpha))
                mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.4, 1.0, 0.5)))
                local mdl = fx.node:GetComponent("StaticModel")
                if mdl then mdl:SetMaterial(mat) end

                -- 光照衰减
                local pl = fx.node:GetComponent("Light")
                if pl then
                    local bright = 2.5
                    if fx.life < 1.0 then bright = bright * fx.life end
                    pl.brightness = bright
                end
            end

        elseif fx.type == "wind_tall" then
            fx.life = fx.life - dt
            if fx.life <= 0 then
                table.insert(toRemove, i)
            else
                -- 旋转风柱（全圆 360 度旋转）
                fx.spinAngle = fx.spinAngle + dt * 150
                local r = fx.radius * 0.7
                local h = fx.height or 20
                for j, pNode in ipairs(fx.pillarNodes) do
                    local baseA = (j - 1) * 45
                    local a = math.rad(baseA + fx.spinAngle)
                    pNode.position = fx.origin + Vector3(
                        math.sin(a) * r, h * 0.5, math.cos(a) * r)
                    pNode.rotation = Quaternion(baseA + fx.spinAngle, Vector3.UP)
                    -- 高度脉动
                    local hPulse = h + math.sin(fx.life * 3 + j) * 1.0
                    pNode.scale = Vector3(0.12, hPulse, 0.12)
                end

                -- 主体透明度渐隐
                local alpha = 0.1
                if fx.life < 1.0 then alpha = alpha * fx.life end
                local mat = GameConfig.CreateAlphaMaterial(Color(0.3, 0.9, 0.4, alpha))
                mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.4, 1.0, 0.5)))
                local mdl = fx.node:GetComponent("StaticModel")
                if mdl then mdl:SetMaterial(mat) end

                -- 光照衰减
                local pl = fx.node:GetComponent("Light")
                if pl then
                    local bright = 3.0
                    if fx.life < 1.0 then bright = bright * fx.life end
                    pl.brightness = bright
                end
            end

        elseif fx.type == "wind_semi_cylinder" then
            fx.life = fx.life - dt
            if fx.life <= 0 then
                table.insert(toRemove, i)
            else
                -- 旋转风柱（仅在前方半圆范围内旋转）
                fx.spinAngle = fx.spinAngle + dt * 120
                local r = fx.radius * 0.7
                local h = fx.height or 20
                for j, pNode in ipairs(fx.pillarNodes) do
                    -- 8 根柱子在前方 180 度内均匀分布 + 旋转偏移
                    local baseA = (j - 1) * (180 / 7) - 90
                    local a = math.rad(baseA + fx.spinAngle * 0.3)
                    pNode.position = fx.origin + Vector3(
                        math.sin(a) * r, h * 0.5, math.cos(a) * r)
                    pNode.rotation = Quaternion(baseA + fx.spinAngle, Vector3.UP)
                    -- 高度脉动
                    local hPulse = h + math.sin(fx.life * 3 + j) * 1.0
                    pNode.scale = Vector3(0.12, hPulse, 0.12)
                end

                -- 主体透明度渐隐
                local alpha = 0.1
                if fx.life < 1.0 then alpha = alpha * fx.life end
                local mat = GameConfig.CreateAlphaMaterial(Color(0.3, 0.9, 0.4, alpha))
                mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.4, 1.0, 0.5)))
                local mdl = fx.node:GetComponent("StaticModel")
                if mdl then mdl:SetMaterial(mat) end

                -- 光照衰减
                local pl = fx.node:GetComponent("Light")
                if pl then
                    local bright = 3.0
                    if fx.life < 1.0 then bright = bright * fx.life end
                    pl.brightness = bright
                end
            end

        elseif fx.type == "sword_path" then
            fx.life = fx.life - dt
            if fx.life <= 0 then
                table.insert(toRemove, i)
            else
                -- 脉动透明度
                local pulse = 0.25 + math.sin(fx.life * 6) * 0.08
                local alpha = pulse
                -- 最后 1 秒渐隐
                if fx.life < 1.0 then
                    alpha = alpha * fx.life
                end
                local pathMat = GameConfig.CreateAlphaMaterial(Color(0.3, 0.7, 1.0, alpha))
                pathMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.4, 0.8, 1.2)))
                local mdl = fx.node:GetComponent("StaticModel")
                if mdl then mdl:SetMaterial(pathMat) end

                -- 光照随时间衰减
                local pl = fx.node:GetComponent("Light")
                if pl then
                    local bright = 3.0
                    if fx.life < 1.0 then bright = bright * fx.life end
                    pl.brightness = bright
                end

                -- 随机砍击闪光（每 0.3~0.5 秒一次）
                fx.slashFlashTimer = fx.slashFlashTimer + dt
                if fx.slashFlashTimer >= 0.35 then
                    fx.slashFlashTimer = 0
                    -- 在剑道范围内随机位置生成闪光
                    local randFwd = math.random() * fx.length
                    local randSide = (math.random() - 0.5) * fx.halfWidth * 2
                    local right = Vector3(fx.forward.z, 0, -fx.forward.x)
                    local flashPos = fx.origin + fx.forward * randFwd + right * randSide + Vector3(0, 0.2, 0)
                    local flashNode = scene_:CreateChild("SwordSlashFlash")
                    flashNode.position = flashPos
                    local fMdl = flashNode:CreateComponent("StaticModel")
                    fMdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
                    fMdl:SetMaterial(makeGlow(Color(0.6, 0.9, 1.0, 1.0), 4.0))
                    flashNode.scale = Vector3(0.3, 0.1, 0.6)
                    flashNode.rotation = Quaternion(math.random(0, 360), Vector3.UP)
                    table.insert(fx.slashFlashNodes, { node = flashNode, life = 0.2 })
                end
                -- 更新闪光生命期
                for j = #fx.slashFlashNodes, 1, -1 do
                    local sf = fx.slashFlashNodes[j]
                    sf.life = sf.life - dt
                    if sf.life <= 0 then
                        sf.node:Remove()
                        table.remove(fx.slashFlashNodes, j)
                    else
                        local s = sf.life / 0.2
                        sf.node.scale = Vector3(0.3 * s, 0.1 * s, 0.6 * s)
                    end
                end
            end

        elseif fx.type == "giant_sword" then
            fx.life = fx.life - dt
            if fx.life <= 0 then
                table.insert(toRemove, i)
            else
                -- 渐隐透明度
                local alpha = math.min(1, fx.life / fx.maxLife) * 0.35
                local swordMat = GameConfig.CreateAlphaMaterial(Color(1.0, 0.85, 0.2, alpha))
                swordMat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.5, 1.2, 0.3)))
                local mdl = fx.node:GetComponent("StaticModel")
                if mdl then mdl:SetMaterial(swordMat) end
                -- 光照衰减
                local pl = fx.node:GetComponent("Light")
                if pl then
                    pl.brightness = 5.0 * math.min(1, fx.life / fx.maxLife)
                end
            end

        elseif fx.type == "explosion_wave" then
            fx.life = fx.life - dt
            if fx.life <= 0 then
                table.insert(toRemove, i)
            else
                -- 扩散环膨胀
                local pct = 1.0 - fx.life / fx.maxLife
                local s = 2.0 + (fx.maxRadius - 2.0) * pct
                fx.node.scale = Vector3(s, 0.3 * (1.0 - pct * 0.5), s)
                -- 透明度渐隐
                local alpha = 0.4 * (1.0 - pct)
                local waveMat = GameConfig.CreateAlphaMaterial(Color(1.0, 0.5, 0.2, alpha))
                waveMat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.5, 0.8, 0.3)))
                local mdl = fx.node:GetComponent("StaticModel")
                if mdl then mdl:SetMaterial(waveMat) end
            end

        elseif fx.type == "sword_wave" then
            fx.life = fx.life - dt
            if fx.life <= 0 then
                table.insert(toRemove, i)
            else
                -- 剑波向外扩散
                local pct = 1.0 - fx.life / fx.maxLife
                local curR = fx.maxRadius * pct
                for _, wn in ipairs(fx.waveNodes) do
                    local a = wn.angle
                    wn.node.position = fx.center + Vector3(
                        math.cos(a) * curR, 0.2, math.sin(a) * curR)
                    -- 拉长变窄
                    local scaleZ = 1.0 + curR * 0.3
                    local alpha = 0.5 * (1.0 - pct)
                    wn.node.scale = Vector3(0.15, 2.5 * (1.0 - pct * 0.3), scaleZ)
                end
            end
        end
    end

    -- 移除失效特效（倒序）
    for i = #toRemove, 1, -1 do
        local idx = toRemove[i]
        local fx = activeEffects_[idx]
        if fx.node then fx.node:Remove() end
        if fx.nodes then
            for _, n in ipairs(fx.nodes) do n:Remove() end
        end
        -- 剑道边缘节点 + 残余闪光清理
        if fx.edgeNodes then
            for _, n in ipairs(fx.edgeNodes) do n:Remove() end
        end
        if fx.slashFlashNodes then
            for _, sf in ipairs(fx.slashFlashNodes) do sf.node:Remove() end
        end
        -- 半圆弧线 + 残余闪光清理
        if fx.arcNodes then
            for _, n in ipairs(fx.arcNodes) do n:Remove() end
        end
        if fx.flashNodes then
            for _, sf in ipairs(fx.flashNodes) do sf.node:Remove() end
        end
        -- 风柱清理
        if fx.pillarNodes then
            for _, n in ipairs(fx.pillarNodes) do n:Remove() end
        end
        -- 剑波节点清理（sword_wave）
        if fx.waveNodes then
            for _, wn in ipairs(fx.waveNodes) do wn.node:Remove() end
        end
        -- 额外节点清理（半圆柱体地面光照等）
        if fx.extraNodes then
            for _, n in ipairs(fx.extraNodes) do n:Remove() end
        end
        table.remove(activeEffects_, idx)
    end
end

-- ============================================================================
-- 公开接口
-- ============================================================================

--- 近战 hit frame 回调 — 由 MeleeWeaponView 在动画命中帧调用
local function onMeleeHitFrame(weaponId, attackType)
    local cfg = GameConfig.Weapons[weaponId]
    if not cfg then return end

    local camPos, camDir = getCamPosDir()
    local rangeMult = LevelSystem.GetRangeMult() * EquipmentSystem.GetRangeMult() * KillBonusSystem.GetRangeMult()
    local sizeMult  = LevelSystem.GetAttackSizeMult()

    local range  = cfg.range * rangeMult
    local dotMin = cfg.dotMin / sizeMult
    local damage = cfg.damage

    -- 下劈连招：1.5x 伤害
    if attackType == "DOWNWARD" then
        damage = math.floor(damage * 1.5)
    end

    -- 命中锥形内所有敌人
    local hitIds = EnemyManager.MeleeConeAttack(camPos, camDir, range, dotMin, damage)
    if #hitIds > 0 then
        -- 击退
        local kbForce = cfg.knockbackForce or 6.0
        if attackType == "DOWNWARD" then kbForce = kbForce * 1.5 end
        for _, eid in ipairs(hitIds) do
            EnemyManager.ApplyKnockback(eid, camDir, kbForce)
            EquipmentSystem.OnAttackHit(eid, damage, camPos + camDir * 1.5)
        end
        -- 命中音效 + 屏幕震动
        AudioManager.PlayHitPunch()
        MeleeWeaponView.TriggerShake()
    end
end

---@param scene Scene
---@param getPos function
---@param getCam function
function WeaponSystem.Init(scene, getPos, getCam)
    scene_ = scene
    getPlayerPos_ = getPos
    getCameraNode_ = getCam
    cooldowns_ = {}
    activeEffects_ = {}
    currentIndex_ = 1
    currentSkillSlot_ = 0
    leftHandIndex_ = 1
    leftHandList_ = {}
    -- 初始化近战武器视图（右手始终显示剑）
    MeleeWeaponView.Init(scene_, getCameraNode_(), onMeleeHitFrame)
    -- 初始化魔法/远程武器视图（左手）
    MagicWeaponView.Init(scene_, getCameraNode_())
    WeaponSystem.RefreshWeapons()
    print("[WeaponSystem] 双手武器系统初始化完成")
end

--- 刷新可用武器列表（拾取物品后调用）
--- iron_sword 始终在首位作为基础武器（右手），无需拾取
function WeaponSystem.RefreshWeapons()
    availableWeapons_ = { "iron_sword" }
    for _, itemId in ipairs(GameConfig.Weapons.Order) do
        if itemId ~= "iron_sword" and GameManager.HasItem(itemId) then
            table.insert(availableWeapons_, itemId)
        end
    end
    -- 构建左手列表
    leftHandList_ = buildLeftHandList()
    -- 边界检查
    if leftHandIndex_ > #leftHandList_ then
        leftHandIndex_ = math.max(1, #leftHandList_)
    end
    -- 更新双手武器可见性
    WeaponSystem.UpdateWeaponVisibility()
    if onWeaponChanged_ then onWeaponChanged_() end
end

---@param dt number
function WeaponSystem.Update(dt)
    if not scene_ then return end

    -- 冷却更新
    for id, t in pairs(cooldowns_) do
        if t > 0 then
            cooldowns_[id] = math.max(0, t - dt)
        end
    end

    -- Q/E/手柄LB/RB 切换左手武器（仅武器条目）
    if input:GetKeyPress(KEY_Q) or MobileControls.WasPressed("prevWeapon") or GamepadControls.WasPressed("prevWeapon") then
        WeaponSystem.SwitchWeaponPrev()
    elseif input:GetKeyPress(KEY_E) or MobileControls.WasPressed("nextWeapon") or GamepadControls.WasPressed("nextWeapon") then
        WeaponSystem.SwitchWeaponNext()
    end

    -- 滚轮切换左手道具/技能（仅技能条目）
    local wheel = input.mouseMoveWheel
    if wheel > 0 then
        WeaponSystem.SwitchSkillNext()
    elseif wheel < 0 then
        WeaponSystem.SwitchSkillPrev()
    end

    -- 右键/手柄Y：Shift+RMB 组合技优先，否则普通剑攻击
    if input:GetMouseButtonPress(MOUSEB_RIGHT) or MobileControls.WasPressed("attackRight") or GamepadControls.WasPressed("attackRight") then
        local FPC = require("core.FirstPersonController")
        local comboState = FPC.GetComboState()
        if comboState ~= "idle" then
            -- 组合技进行中，吞掉右键
        elseif input:GetKeyDown(KEY_SHIFT) and FPC.IsComboAvailable() then
            -- 未觉醒时不可使用组合技
            if AwakeningSystem.GetLevel() < 1 then
                print("[WeaponSystem] 尚未觉醒，无法使用组合技")
            else
                -- 根据 WASD 决定组合技类型
                local comboType = "sword_path"  -- 默认/W
                if input:GetKeyDown(KEY_A) then
                    comboType = "ice_sweep"
                elseif input:GetKeyDown(KEY_D) then
                    comboType = "fire_sweep"
                elseif input:GetKeyDown(KEY_S) then
                    comboType = "wind_release"
                end
                FPC.StartComboCharge(comboType)
            end
        else
            WeaponSystem.AttackRight()
        end
    end

    -- 左键/手柄X：左手道具/技能使用
    if input:GetMouseButtonPress(MOUSEB_LEFT) or MobileControls.WasPressed("attackLeft") or GamepadControls.WasPressed("attackLeft") then
        WeaponSystem.AttackLeft()
    end

    -- 更新武器视图（双手同时更新）
    MeleeWeaponView.Update(dt)
    MagicWeaponView.Update(dt)

    -- 更新特效
    updateEffects(dt)
end

--- 切换左手道具（下一个，遍历全部）
function WeaponSystem.SwitchLeftNext()
    leftHandList_ = buildLeftHandList()
    if #leftHandList_ <= 0 then return end
    leftHandIndex_ = (leftHandIndex_ % #leftHandList_) + 1
    applyLeftHandSlot(leftHandList_[leftHandIndex_])
end

--- 切换左手道具（上一个，遍历全部）
function WeaponSystem.SwitchLeftPrev()
    leftHandList_ = buildLeftHandList()
    if #leftHandList_ <= 0 then return end
    leftHandIndex_ = ((leftHandIndex_ - 2) % #leftHandList_) + 1
    applyLeftHandSlot(leftHandList_[leftHandIndex_])
end

--- 按类型跳转到下一个武器条目（Q/E 用）
function WeaponSystem.SwitchWeaponNext()
    leftHandList_ = buildLeftHandList()
    if #leftHandList_ <= 0 then return end
    local start = leftHandIndex_
    for _ = 1, #leftHandList_ do
        local idx = (start % #leftHandList_) + 1
        start = idx
        if leftHandList_[idx].type == "weapon" then
            leftHandIndex_ = idx
            applyLeftHandSlot(leftHandList_[idx])
            return
        end
    end
end

--- 按类型跳转到上一个武器条目（Q/E 用）
function WeaponSystem.SwitchWeaponPrev()
    leftHandList_ = buildLeftHandList()
    if #leftHandList_ <= 0 then return end
    local start = leftHandIndex_
    for _ = 1, #leftHandList_ do
        local idx = ((start - 2) % #leftHandList_) + 1
        start = idx
        if leftHandList_[idx].type == "weapon" then
            leftHandIndex_ = idx
            applyLeftHandSlot(leftHandList_[idx])
            return
        end
    end
end

--- 按类型跳转到下一个技能/道具条目（滚轮用）
function WeaponSystem.SwitchSkillNext()
    leftHandList_ = buildLeftHandList()
    if #leftHandList_ <= 0 then return end
    local start = leftHandIndex_
    for _ = 1, #leftHandList_ do
        local idx = (start % #leftHandList_) + 1
        start = idx
        if leftHandList_[idx].type == "skill" then
            leftHandIndex_ = idx
            applyLeftHandSlot(leftHandList_[idx])
            return
        end
    end
end

--- 按类型跳转到上一个技能/道具条目（滚轮用）
function WeaponSystem.SwitchSkillPrev()
    leftHandList_ = buildLeftHandList()
    if #leftHandList_ <= 0 then return end
    local start = leftHandIndex_
    for _ = 1, #leftHandList_ do
        local idx = ((start - 2) % #leftHandList_) + 1
        start = idx
        if leftHandList_[idx].type == "skill" then
            leftHandIndex_ = idx
            applyLeftHandSlot(leftHandList_[idx])
            return
        end
    end
end

--- 兼容旧调用
function WeaponSystem.SwitchNext() WeaponSystem.SwitchLeftNext() end
function WeaponSystem.SwitchPrev() WeaponSystem.SwitchLeftPrev() end

--- 右手攻击（右键）：始终挥剑
function WeaponSystem.AttackRight()
    local cdMult = LevelSystem.GetCooldownMult() * EquipmentSystem.GetCooldownMult() * KillBonusSystem.GetCooldownMult() * KillBonusSystem.GetFrenzySpeedMult()
    local cfg = GameConfig.Weapons["iron_sword"]
    if not cfg then return end
    local cd = cooldowns_["iron_sword"] or 0
    if cd > 0 then return end

    MeleeWeaponView.TriggerAttack("iron_sword")
    cooldowns_["iron_sword"] = cfg.cooldown * cdMult
    AudioManager.PlaySwordSwing()
end

--- 左手攻击（左键）：使用左手当前道具/技能
function WeaponSystem.AttackLeft()
    leftHandList_ = buildLeftHandList()
    if #leftHandList_ == 0 then return end
    if leftHandIndex_ < 1 or leftHandIndex_ > #leftHandList_ then
        leftHandIndex_ = 1
    end

    local slot = leftHandList_[leftHandIndex_]
    if not slot then return end

    -- 技能模式
    if slot.type == "skill" then
        local skillId = SKILL_ORDER_REF[slot.slotIndex]
        if skillId then
            SkillSystem.TryUseSkill(skillId)
        end
        return
    end

    -- 武器模式
    local weaponId = slot.id
    local cfg = GameConfig.Weapons[weaponId]
    if not cfg then return end

    local cdMult = LevelSystem.GetCooldownMult() * EquipmentSystem.GetCooldownMult() * KillBonusSystem.GetCooldownMult() * KillBonusSystem.GetFrenzySpeedMult()
    local rangeMult = LevelSystem.GetRangeMult() * EquipmentSystem.GetRangeMult() * KillBonusSystem.GetRangeMult()
    local extraHits = LevelSystem.GetExtraHitCount()
    local extraProjectiles = LevelSystem.GetAttackCountBonus()

    local cd = cooldowns_[weaponId] or 0
    if cd > 0 then return end

    local attackFn = ATTACKS[weaponId]
    if attackFn then
        -- 触发左手施法动画
        MagicWeaponView.TriggerCast()
        attackFn()
        -- 额外弹体：对发射型武器（火球、追踪符）扩散发射
        if extraProjectiles > 0 then
            if weaponId == "fire_dragon_card" or weaponId == "exorcism_talisman" then
                local _, camDir = getCamPosDir()
                local spreadAngle = 12
                for i = 1, extraProjectiles do
                    local side = (i % 2 == 1) and 1 or -1
                    local deg = math.ceil(i / 2) * spreadAngle * side
                    local spreadDir = Quaternion(deg, Vector3.UP) * camDir
                    attackFn(spreadDir)
                end
            end
        end
        -- 额外攻击：仅对直接伤害型武器生效
        if extraHits > 0 and (cfg.dotMin or cfg.range) and cfg.damage then
            local camPos, camDir = getCamPosDir()
            local range = (cfg.range or 5) * rangeMult
            for i = 1, extraHits do
                EnemyManager.AOEDamage(camPos + camDir * (range * 0.5), range * 0.5, math.floor(cfg.damage * 0.5))
            end
        end
        cooldowns_[weaponId] = cfg.cooldown * cdMult
        AudioManager.PlaySkillSFX(weaponId)
    end
end

--- 兼容旧调用
function WeaponSystem.Attack()
    WeaponSystem.AttackRight()
end

--- 获取右手武器 ID（始终是 iron_sword）
---@return string
function WeaponSystem.GetRightHandWeaponId()
    return "iron_sword"
end

--- 获取左手当前道具/技能信息
---@return table|nil { type="weapon"|"skill", id=string, slotIndex=number|nil }
function WeaponSystem.GetLeftHandSlot()
    leftHandList_ = buildLeftHandList()
    if #leftHandList_ == 0 then return nil end
    if leftHandIndex_ < 1 or leftHandIndex_ > #leftHandList_ then
        leftHandIndex_ = 1
    end
    return leftHandList_[leftHandIndex_]
end

--- 获取左手武器 ID（技能模式时返回 nil）
---@return string|nil
function WeaponSystem.GetLeftHandWeaponId()
    local slot = WeaponSystem.GetLeftHandSlot()
    if not slot then return nil end
    if slot.type == "weapon" then return slot.id end
    return nil
end

--- 获取当前武器 ID（兼容旧调用，返回左手武器ID，技能模式返回nil）
---@return string|nil
function WeaponSystem.GetCurrentWeaponId()
    return WeaponSystem.GetLeftHandWeaponId()
end

--- 获取指定武器的冷却时间
---@param weaponId string
---@return number
function WeaponSystem.GetCooldown(weaponId)
    return cooldowns_[weaponId or "iron_sword"] or 0
end

--- 获取当前槽位类型
---@return string "weapon"|"skill"
function WeaponSystem.GetCurrentSlotType()
    local slot = WeaponSystem.GetLeftHandSlot()
    if slot and slot.type == "skill" then return "skill" end
    return "weapon"
end

--- 获取当前技能槽位（1-6），仅在类型为 "skill" 时有效
---@return number
function WeaponSystem.GetCurrentSkillSlot()
    local slot = WeaponSystem.GetLeftHandSlot()
    if slot and slot.type == "skill" then return slot.slotIndex end
    return 0
end

---@param cb function
function WeaponSystem.OnWeaponChanged(cb) onWeaponChanged_ = cb end

--- 更新武器模型可见性（双手系统：右手始终显示剑，左手显示当前道具）
function WeaponSystem.UpdateWeaponVisibility()
    -- 右手：始终显示剑
    MeleeWeaponView.SetVisible(true)
    MeleeWeaponView.SetWeapon("iron_sword")

    -- 左手：显示当前选中的道具
    local slot = WeaponSystem.GetLeftHandSlot()
    if slot and slot.type == "weapon" then
        MagicWeaponView.SetWeapon(slot.id)
        MagicWeaponView.SetVisible(true)
    elseif slot and slot.type == "skill" then
        -- 技能模式：隐藏左手模型（技能是直接释放的）
        MagicWeaponView.SetVisible(false)
    else
        -- 没有左手道具
        MagicWeaponView.SetVisible(false)
    end
end

--- 兼容旧调用
function WeaponSystem.UpdateMeleeVisibility()
    WeaponSystem.UpdateWeaponVisibility()
end

--- 获取翠笛增益状态
---@return number atkSpdBonus 攻速加成 (0.0 无加成)
---@return number moveSpdBonus 移速加成 (0.0 无加成)
function WeaponSystem.GetJadeBuffBonus()
    for _, fx in ipairs(activeEffects_) do
        if fx.type == "jade_buff" and not fx.dead and fx.life > 0 then
            return fx.atkSpdBonus or 0, fx.moveSpdBonus or 0
        end
    end
    return 0, 0
end

--- 仅清除冷却和活跃特效（广告复活用，保留武器/技能选择状态）
function WeaponSystem.ClearCooldowns()
    for _, fx in ipairs(activeEffects_) do
        if fx.node then fx.node:Remove() end
        if fx.nodes then
            for _, n in ipairs(fx.nodes) do n:Remove() end
        end
    end
    activeEffects_ = {}
    cooldowns_ = {}
    PlayerHealth.SetShielded(false)
end

--- 清理所有特效
function WeaponSystem.Reset()
    WeaponSystem.ClearCooldowns()
    MeleeWeaponView.Reset()
    MagicWeaponView.Reset()
    currentIndex_ = 1
    currentSkillSlot_ = 0
    leftHandIndex_ = 1
    leftHandList_ = {}
    WeaponSystem.RefreshWeapons()
end

-- ============================================================================
-- 组合技 — 半圆/圆形 3D 特效
-- ============================================================================

--- 创建半圆扇形特效（冰封/烈焰横扫）
---@param origin Vector3   玩家位置
---@param forward Vector3  朝向（水平单位向量）
---@param radius number    半径 m
---@param duration number  持续时间 s
---@param element string   "ice" 或 "fire"
function WeaponSystem.CreateSweepEffect(origin, forward, radius, duration, element)
    if not scene_ then return end

    local yawAngle = math.deg(math.atan(forward.x, forward.z))

    -- 颜色配置
    local baseColor, emissiveColor, lightColor
    if element == "ice" then
        baseColor    = Color(0.2, 0.5, 1.0, 0.2)
        emissiveColor = Color(0.3, 0.6, 1.2)
        lightColor   = Color(0.3, 0.6, 1.0, 1.0)
    else -- fire
        baseColor    = Color(1.0, 0.3, 0.05, 0.2)
        emissiveColor = Color(1.2, 0.5, 0.15)
        lightColor   = Color(1.0, 0.4, 0.1, 1.0)
    end

    -- 主体：扁平圆柱代表半圆区域（用 Cylinder 缩放）
    local sweepNode = scene_:CreateChild("SweepEffect")
    sweepNode.position = origin + forward * (radius * 0.25)
    sweepNode.rotation = Quaternion(yawAngle, Vector3.UP)

    local mdl = sweepNode:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    local sweepMat = GameConfig.CreateAlphaMaterial(baseColor)
    sweepMat:SetShaderParameter("MatEmissiveColor", Variant(emissiveColor))
    mdl:SetMaterial(sweepMat)
    -- Cylinder 默认 1x1x1, 缩放为 直径×薄×直径
    sweepNode.scale = Vector3(radius * 2, 0.08, radius * 2)

    -- 地面光照
    local pl = sweepNode:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = radius * 0.8
    pl.color = lightColor
    pl.brightness = 3.0

    -- 边缘弧线（4 条窄长方体沿半圆弧排列）
    local arcNodes = {}
    local arcCount = 6
    for i = 1, arcCount do
        local angle = math.rad(-90 + (i - 1) * (180 / (arcCount - 1)))
        local arcNode = scene_:CreateChild("SweepArc")
        local worldAngle = math.rad(yawAngle) + angle
        arcNode.position = origin + Vector3(
            math.sin(worldAngle) * radius,
            0.05,
            math.cos(worldAngle) * radius
        )
        arcNode.rotation = Quaternion(yawAngle + math.deg(angle), Vector3.UP)
        local aMdl = arcNode:CreateComponent("StaticModel")
        aMdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        aMdl:SetMaterial(makeGlow(
            Color(baseColor.r * 1.5, baseColor.g * 1.5, baseColor.b * 1.5, 1.0), 3.0))
        arcNode.scale = Vector3(0.06, 0.15, radius * 0.35)
        table.insert(arcNodes, arcNode)
    end

    table.insert(activeEffects_, {
        type = "sweep_" .. element,
        node = sweepNode,
        arcNodes = arcNodes,
        life = duration,
        maxLife = duration,
        origin = origin,
        forward = forward,
        radius = radius,
        element = element,
        baseColor = baseColor,
        emissiveColor = emissiveColor,
        flashTimer = 0,
        flashNodes = {},
    })
end

--- 创建圆形风遁特效
---@param origin Vector3   玩家位置
---@param radius number    半径 m
---@param duration number  持续时间 s
function WeaponSystem.CreateWindEffect(origin, radius, duration)
    if not scene_ then return end

    -- 主体：扁平圆柱
    local windNode = scene_:CreateChild("WindEffect")
    windNode.position = origin
    local mdl = windNode:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    local windMat = GameConfig.CreateAlphaMaterial(Color(0.3, 0.9, 0.4, 0.15))
    windMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.4, 1.0, 0.5)))
    mdl:SetMaterial(windMat)
    windNode.scale = Vector3(radius * 2, 0.08, radius * 2)

    -- 地面光照
    local pl = windNode:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = radius * 0.6
    pl.color = Color(0.4, 1.0, 0.5, 1.0)
    pl.brightness = 2.5

    -- 旋转风柱粒子（8 个竖条围绕圆周）
    local pillarNodes = {}
    for i = 1, 8 do
        local angle = math.rad((i - 1) * 45)
        local pNode = scene_:CreateChild("WindPillar")
        pNode.position = origin + Vector3(
            math.sin(angle) * radius * 0.7,
            0.5,
            math.cos(angle) * radius * 0.7
        )
        local pMdl = pNode:CreateComponent("StaticModel")
        pMdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        pMdl:SetMaterial(makeGlow(Color(0.4, 1.0, 0.6, 0.8), 2.5))
        pNode.scale = Vector3(0.08, 2.0, 0.08)
        table.insert(pillarNodes, pNode)
    end

    table.insert(activeEffects_, {
        type = "wind_release",
        node = windNode,
        pillarNodes = pillarNodes,
        life = duration,
        maxLife = duration,
        origin = origin,
        radius = radius,
        spinAngle = 0,
    })
end

--- 创建 20 米高全圆柱体风遁特效（觉醒 lv2 用）
---@param origin Vector3   玩家位置
---@param radius number    半径 m
---@param height number    高度 m（如 20）
---@param duration number  持续时间 s
function WeaponSystem.CreateTallWindEffect(origin, radius, height, duration)
    if not scene_ then return end

    -- 主体：高圆柱体
    local windNode = scene_:CreateChild("WindTallEffect")
    windNode.position = origin + Vector3(0, height * 0.5, 0)
    local mdl = windNode:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    local windMat = GameConfig.CreateAlphaMaterial(Color(0.3, 0.9, 0.4, 0.1))
    windMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.4, 1.0, 0.5)))
    mdl:SetMaterial(windMat)
    windNode.scale = Vector3(radius * 2, height, radius * 2)

    -- 顶部光照
    local topLight = scene_:CreateChild("WindTopLight")
    topLight.position = origin + Vector3(0, height, 0)
    local pl = topLight:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = radius * 1.2
    pl.color = Color(0.4, 1.0, 0.5, 1.0)
    pl.brightness = 3.0

    -- 底部地面光照
    local groundLight = scene_:CreateChild("WindGroundLight")
    groundLight.position = origin
    local pl2 = groundLight:CreateComponent("Light")
    pl2.lightType = LIGHT_POINT
    pl2.castShadows = false
    pl2.range = radius * 0.8
    pl2.color = Color(0.3, 1.0, 0.4, 1.0)
    pl2.brightness = 2.5

    -- 旋转风柱粒子（8 个竖条围绕圆周，高度 = height）
    local pillarNodes = {}
    for i = 1, 8 do
        local angle = math.rad((i - 1) * 45)
        local pNode = scene_:CreateChild("WindPillarTall")
        pNode.position = origin + Vector3(
            math.sin(angle) * radius * 0.7,
            height * 0.5,
            math.cos(angle) * radius * 0.7
        )
        local pMdl = pNode:CreateComponent("StaticModel")
        pMdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        pMdl:SetMaterial(makeGlow(Color(0.4, 1.0, 0.6, 0.8), 2.5))
        pNode.scale = Vector3(0.12, height, 0.12)
        table.insert(pillarNodes, pNode)
    end

    table.insert(activeEffects_, {
        type = "wind_tall",
        node = windNode,
        pillarNodes = pillarNodes,
        extraNodes = { topLight, groundLight },
        life = duration,
        maxLife = duration,
        origin = origin,
        radius = radius,
        height = height,
        spinAngle = 0,
    })
end

--- 创建半圆柱体风遁特效（觉醒 lv2 用）
---@param origin Vector3   玩家位置
---@param forward Vector3  朝向（水平单位向量）
---@param radius number    半径 m
---@param height number    高度 m（如 20）
---@param duration number  持续时间 s
function WeaponSystem.CreateWindSemiCylinderEffect(origin, forward, radius, height, duration)
    if not scene_ then return end

    -- 主体：高圆柱体（全圆柱，用位置偏移模拟半圆）
    local windNode = scene_:CreateChild("WindSemiCylinder")
    -- 半圆柱中心偏移到前方 radius/2 处
    local halfOffset = forward * (radius * 0.5)
    windNode.position = origin + halfOffset + Vector3(0, height * 0.5, 0)
    local mdl = windNode:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    local windMat = GameConfig.CreateAlphaMaterial(Color(0.3, 0.9, 0.4, 0.1))
    windMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.4, 1.0, 0.5)))
    mdl:SetMaterial(windMat)
    -- Cylinder 默认高1，缩放为 直径 x 高度 x 直径
    windNode.scale = Vector3(radius * 2, height, radius * 2)

    -- 顶部光照
    local pl = windNode:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = radius * 1.2
    pl.color = Color(0.4, 1.0, 0.5, 1.0)
    pl.brightness = 3.0

    -- 底部地面光照
    local groundLight = scene_:CreateChild("WindGroundLight")
    groundLight.position = origin
    local pl2 = groundLight:CreateComponent("Light")
    pl2.lightType = LIGHT_POINT
    pl2.castShadows = false
    pl2.range = radius * 0.8
    pl2.color = Color(0.3, 1.0, 0.4, 1.0)
    pl2.brightness = 2.0

    -- 旋转风柱粒子（8 个竖条围绕半圆，仅前方 180 度）
    local pillarNodes = {}
    local yawAngle = math.deg(math.atan(forward.x, forward.z))
    for i = 1, 8 do
        -- 在前方 180 度内均匀分布
        local angle = math.rad(yawAngle - 90 + (i - 1) * (180 / 7))
        local pNode = scene_:CreateChild("WindPillarTall")
        pNode.position = origin + Vector3(
            math.sin(angle) * radius * 0.7,
            height * 0.5,
            math.cos(angle) * radius * 0.7
        )
        local pMdl = pNode:CreateComponent("StaticModel")
        pMdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        pMdl:SetMaterial(makeGlow(Color(0.4, 1.0, 0.6, 0.8), 2.5))
        pNode.scale = Vector3(0.12, height, 0.12)
        table.insert(pillarNodes, pNode)
    end

    table.insert(activeEffects_, {
        type = "wind_semi_cylinder",
        node = windNode,
        pillarNodes = pillarNodes,
        extraNodes = { groundLight },
        life = duration,
        maxLife = duration,
        origin = origin,
        radius = radius,
        height = height,
        spinAngle = 0,
    })
end

-- ============================================================================
-- 剑道组合技 — 3D 剑道特效
-- ============================================================================

--- 创建剑道 3D 特效（由 FirstPersonController 调用）
---@param origin Vector3   剑道起点（玩家位置 + 偏移）
---@param forward Vector3  剑道方向（水平单位向量）
---@param length number    长度 m
---@param width number     宽度 m
---@param duration number  持续时间 s
function WeaponSystem.CreateSwordPath(origin, forward, length, width, duration)
    if not scene_ then return end

    -- 剑道中心在 origin 前方 length/2 处
    local center = origin + forward * (length * 0.5)
    local yawAngle = math.deg(math.atan(forward.x, forward.z))

    -- === 主体：半透明发光长方体 ===
    local pathNode = scene_:CreateChild("SwordPath")
    pathNode.position = center
    pathNode.rotation = Quaternion(yawAngle, Vector3.UP)

    local mdl = pathNode:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    -- 青白色半透明发光材质
    local pathMat = GameConfig.CreateAlphaMaterial(Color(0.3, 0.7, 1.0, 0.25))
    pathMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.4, 0.8, 1.2)))
    mdl:SetMaterial(pathMat)
    -- Box 默认 1x1x1，缩放为 width x 0.1 x length
    pathNode.scale = Vector3(width, 0.1, length)

    -- 地面光照
    local pl = pathNode:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = length * 0.6
    pl.color = Color(0.3, 0.7, 1.0, 1.0)
    pl.brightness = 3.0

    -- === 边缘线条（两条窄长方体沿边缘） ===
    local edgeNodes = {}
    for side = -1, 1, 2 do
        local edgeNode = scene_:CreateChild("SwordPathEdge")
        edgeNode.position = center + Quaternion(yawAngle, Vector3.UP) * Vector3(side * width * 0.5, 0.05, 0)
        edgeNode.rotation = Quaternion(yawAngle, Vector3.UP)
        local eMdl = edgeNode:CreateComponent("StaticModel")
        eMdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        local edgeMat = makeGlow(Color(0.5, 0.9, 1.0, 1.0), 3.0)
        eMdl:SetMaterial(edgeMat)
        edgeNode.scale = Vector3(0.05, 0.15, length)
        table.insert(edgeNodes, edgeNode)
    end

    table.insert(activeEffects_, {
        type = "sword_path",
        node = pathNode,
        edgeNodes = edgeNodes,
        life = duration,
        maxLife = duration,
        origin = origin,
        forward = forward,
        length = length,
        halfWidth = width * 0.5,
        slashFlashTimer = 0,
        slashFlashNodes = {},
    })
end

-- ============================================================================
-- 觉醒四/五阶段 新特效
-- ============================================================================

--- 创建金色巨剑特效（觉醒4 sword_path 蓄力时显示）
---@param origin Vector3 剑起始位置
---@param forward Vector3 方向
---@param length number 巨剑长度
---@param width number 巨剑宽度
---@param duration number 持续时间
function WeaponSystem.CreateGiantSwordEffect(origin, forward, length, width, duration)
    if not scene_ then return end

    local center = origin + forward * (length * 0.5)
    local yawAngle = math.deg(math.atan(forward.x, forward.z))

    local swordNode = scene_:CreateChild("GiantSword")
    swordNode.position = center + Vector3(0, 1.0, 0)
    swordNode.rotation = Quaternion(yawAngle, Vector3.UP)

    local mdl = swordNode:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    local swordMat = GameConfig.CreateAlphaMaterial(Color(1.0, 0.85, 0.2, 0.35))
    swordMat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.5, 1.2, 0.3)))
    mdl:SetMaterial(swordMat)
    swordNode.scale = Vector3(width, 3.0, length)

    -- 金色光照
    local pl = swordNode:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = length * 0.8
    pl.color = Color(1.0, 0.85, 0.3, 1.0)
    pl.brightness = 5.0

    table.insert(activeEffects_, {
        type = "giant_sword",
        node = swordNode,
        life = duration,
        maxLife = duration,
    })
end

--- 创建爆炸冲击波特效（觉醒4/5 冰火叠加用）
---@param center Vector3 爆炸中心
---@param maxRadius number 最大半径
---@param duration number 持续时间
---@param element string "ice_fire" 混合元素
function WeaponSystem.CreateExplosionWaveEffect(center, maxRadius, duration, element)
    if not scene_ then return end

    -- 扩散环
    local waveNode = scene_:CreateChild("ExplosionWave")
    waveNode.position = center + Vector3(0, 0.5, 0)
    local mdl = waveNode:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    local waveMat = GameConfig.CreateAlphaMaterial(Color(1.0, 0.5, 0.2, 0.4))
    waveMat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.5, 0.8, 0.3)))
    mdl:SetMaterial(waveMat)
    waveNode.scale = Vector3(2.0, 0.3, 2.0)  -- 初始小圆

    -- 中心火光
    local lightNode = scene_:CreateChild("ExplosionLight")
    lightNode.position = center + Vector3(0, 2.0, 0)
    local pl = lightNode:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = maxRadius * 0.6
    pl.color = Color(1.0, 0.6, 0.2, 1.0)
    pl.brightness = 8.0

    table.insert(activeEffects_, {
        type = "explosion_wave",
        node = waveNode,
        extraNodes = { lightNode },
        life = duration,
        maxLife = duration,
        maxRadius = maxRadius,
        center = center,
    })
end

--- 创建地面剑波特效（觉醒5 sword_path 地面冲击用）
---@param center Vector3 冲击中心
---@param waveCount number 剑波数量
---@param maxRadius number 最大扩散半径
---@param duration number 持续时间
function WeaponSystem.CreateSwordWaveEffect(center, waveCount, maxRadius, duration)
    if not scene_ then return end

    local waveNodes = {}
    for i = 1, waveCount do
        local angle = math.rad((i - 1) * (360 / waveCount))
        local waveNode = scene_:CreateChild("SwordWave")
        waveNode.position = center + Vector3(0, 0.2, 0)
        waveNode.rotation = Quaternion(math.deg(angle), Vector3.UP)

        local mdl = waveNode:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        local waveMat = GameConfig.CreateAlphaMaterial(Color(0.3, 0.7, 1.0, 0.5))
        waveMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.5, 0.9, 1.5)))
        mdl:SetMaterial(waveMat)
        waveNode.scale = Vector3(0.15, 2.5, 1.0)  -- 初始窄长

        table.insert(waveNodes, { node = waveNode, angle = angle })
    end

    -- 中心冲击光照
    local lightNode = scene_:CreateChild("SwordWaveLight")
    lightNode.position = center + Vector3(0, 1.0, 0)
    local pl = lightNode:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = maxRadius * 0.5
    pl.color = Color(0.4, 0.8, 1.0, 1.0)
    pl.brightness = 6.0

    table.insert(activeEffects_, {
        type = "sword_wave",
        waveNodes = waveNodes,
        extraNodes = { lightNode },
        life = duration,
        maxLife = duration,
        maxRadius = maxRadius,
        center = center,
    })
end

return WeaponSystem
