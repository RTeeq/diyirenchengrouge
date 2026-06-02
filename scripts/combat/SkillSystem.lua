-- ============================================================================
-- SkillSystem.lua — 技能系统
-- 6个技能的执行、视觉特效、键位绑定(1-6)、HUD 查询
-- ============================================================================

local GameConfig = require("config.GameConfig")
local GameManager = require("core.GameManager")
local LevelSystem = require("combat.LevelSystem")
local EnemyManager = require("combat.EnemyManager")
local PlayerHealth = require("combat.PlayerHealth")
local EquipmentSystem = require("combat.EquipmentSystem")
local KillBonusSystem = require("combat.KillBonusSystem")
local MobileControls = require("ui.MobileControls")

local SkillSystem = {}

---@type Scene
local scene_ = nil
local getPlayerPos_ = nil
local getCameraNode_ = nil

-- 技能槽位映射：按键 1-6 → 技能 ID（7-12 通过手机按钮或 7-9,0,-,= 触发）
local SKILL_KEYS  = { KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6,
                      KEY_7, KEY_8, KEY_9, KEY_0, KEY_MINUS, KEY_EQUALS }
local SKILL_ORDER = {
    "shockwave", "timeFreeze", "lightningStorm", "fireStorm", "voidPull", "healAura",
    "flameSlash", "iceArmor", "chainLightning", "earthquakeSlam", "shadowClone", "lifeDrain",
}

-- 活跃视觉特效
local activeEffects_ = {}

-- 持续技能状态
local fireStormState_ = nil   -- { timer, tickTimer, range, damage, ticks }
local shieldTimer_ = 0        -- 护盾持续时间
local iceArmorState_ = nil    -- { timer, damageReduction, reflectDamage }
local earthquakeState_ = nil  -- { timer, pos, damage, range }
local shadowCloneState_ = nil -- { timer, attackTimer, interval, damage, clones={node,…} }

-- ============================================================================
-- 属性加成计算（与 WeaponSystem 的乘数链保持一致）
-- ============================================================================

--- 获取技能伤害（基础 * 装备伤害加成）
---@param baseDamage number
---@return number
local function getScaledDamage(baseDamage)
    return math.floor(baseDamage * EquipmentSystem.GetDamageMult())
end

--- 获取技能范围（基础 * 升级范围 * 装备范围 * 击杀范围）
---@param baseRange number
---@return number
local function getScaledRange(baseRange)
    return baseRange * LevelSystem.GetRangeMult() * EquipmentSystem.GetRangeMult() * KillBonusSystem.GetRangeMult()
end

--- 获取技能冷却（基础 * 升级冷却 * 装备冷却 * 击杀冷却 * 狂热加速）
---@param baseCooldown number
---@return number
local function getScaledCooldown(baseCooldown)
    return baseCooldown * LevelSystem.GetCooldownMult() * EquipmentSystem.GetCooldownMult()
        * KillBonusSystem.GetCooldownMult() * KillBonusSystem.GetFrenzySpeedMult()
end

--- 获取技能面积倍率
---@return number
local function getAreaMult()
    return LevelSystem.GetAttackSizeMult()
end

-- ============================================================================
-- 工具函数
-- ============================================================================

local function makeMat(color)
    return GameConfig.CreateMaterial(color)
end

local function makeGlow(color, intensity)
    return GameConfig.CreateEmissiveMaterial(color, intensity)
end

local function makeAlpha(color)
    return GameConfig.CreateAlphaMaterial(color)
end

-- ============================================================================
-- 技能特效实现
-- ============================================================================

local SKILL_EFFECTS = {}

--- 冲击波：AOE 伤害 + 扩展环 + 地面裂纹特效
SKILL_EFFECTS["shockwave"] = function(skillCfg)
    local playerPos = getPlayerPos_()
    local damage = getScaledDamage(skillCfg.damage)
    local range = getScaledRange(skillCfg.range) * getAreaMult()
    EnemyManager.AOEDamage(playerPos, range, damage)

    -- 扩展冲击环
    local node = scene_:CreateChild("SkillShockwave")
    node.position = playerPos + Vector3(0, 0.2, 0)
    local mdl = node:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
    mdl:SetMaterial(makeGlow(Color(0.3, 0.6, 1.0, 1.0), 4.0))
    node.scale = Vector3(0.5, 0.2, 0.5)

    local pl = node:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = 12.0
    pl.color = Color(0.3, 0.6, 1.0)
    pl.brightness = 4.0

    table.insert(activeEffects_, {
        type = "shockwave_expand",
        node = node,
        life = 0.6,
        maxLife = 0.6,
        endScale = range * 2,
    })

    -- 地面冲击波纹（多层扩散环）
    for i = 1, 3 do
        local ring = scene_:CreateChild("ShockRing" .. i)
        ring.position = playerPos + Vector3(0, 0.05 * i, 0)
        local rm = ring:CreateComponent("StaticModel")
        rm:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
        rm:SetMaterial(makeAlpha(Color(0.4, 0.7, 1.0, 0.15)))
        ring.scale = Vector3(0.3, 0.1, 0.3)

        table.insert(activeEffects_, {
            type = "shockwave_expand",
            node = ring,
            life = 0.4 + i * 0.15,
            maxLife = 0.4 + i * 0.15,
            endScale = range * 2.2,
        })
    end

    print("[SkillSystem] 冲击波释放！伤害: " .. damage .. " 范围: " .. string.format("%.1f", range) .. "m")
end

--- 时间冻结：冻结范围内敌人 + 冰晶碎片 + 闪光
SKILL_EFFECTS["timeFreeze"] = function(skillCfg)
    local playerPos = getPlayerPos_()
    local range = getScaledRange(skillCfg.range) * getAreaMult()
    EnemyManager.FreezeEnemies(playerPos, range, skillCfg.duration)

    -- 冰蓝闪光球
    local node = scene_:CreateChild("SkillFreeze")
    node.position = playerPos
    local mdl = node:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    mdl:SetMaterial(makeAlpha(Color(0.5, 0.8, 1.0, 0.2)))
    local s = range
    node.scale = Vector3(s, s, s)

    local pl = node:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = range + 2
    pl.color = Color(0.4, 0.7, 1.0)
    pl.brightness = 5.0

    table.insert(activeEffects_, {
        type = "freeze_flash",
        node = node,
        life = 0.8,
        maxLife = 0.8,
    })

    -- 冰晶碎片围绕效果
    for i = 1, 8 do
        local angle = (i / 8) * 6.28
        local r = range * 0.6
        local crystal = scene_:CreateChild("IceCrystal" .. i)
        crystal.position = playerPos + Vector3(math.cos(angle) * r, 1.5 + math.random() * 1.0, math.sin(angle) * r)
        local cm = crystal:CreateComponent("StaticModel")
        cm:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        cm:SetMaterial(makeGlow(Color(0.6, 0.9, 1.0, 1.0), 3.0))
        crystal.scale = Vector3(0.12, 0.4, 0.12)
        crystal.rotation = Quaternion(math.random() * 360, Vector3(math.random(), math.random(), math.random()):Normalized())

        table.insert(activeEffects_, {
            type = "crystal_fade",
            node = crystal,
            life = 1.0 + math.random() * 0.5,
        })
    end

    print("[SkillSystem] 时间冻结释放！范围: " .. string.format("%.1f", range) .. "m, 持续: " .. skillCfg.duration .. "s")
end

--- 雷暴：多次闪电打击 + 闪电柱 + 地面电弧
SKILL_EFFECTS["lightningStorm"] = function(skillCfg)
    local playerPos = getPlayerPos_()
    local damage = getScaledDamage(skillCfg.damage)
    local range = getScaledRange(skillCfg.range) * getAreaMult()
    local strikes = skillCfg.strikes + LevelSystem.GetExtraHitCount()
    local enemies = EnemyManager.GetAllEnemies()

    -- 收集范围内敌人
    local inRange = {}
    for id, e in pairs(enemies) do
        local dx = e.node.position.x - playerPos.x
        local dz = e.node.position.z - playerPos.z
        if math.sqrt(dx * dx + dz * dz) <= range then
            table.insert(inRange, { id = id, enemy = e })
        end
    end

    -- Round-robin 分配打击
    local hitCount = 0
    for i = 1, strikes do
        if #inRange == 0 then break end
        local idx = ((i - 1) % #inRange) + 1
        local target = inRange[idx]
        EnemyManager.DamageEnemy(target.id, damage)
        hitCount = hitCount + 1

        -- 闪电柱特效（从天而降）
        local sNode = scene_:CreateChild("LightningStrike_" .. i)
        local tPos = target.enemy.node.position
        sNode.position = Vector3(tPos.x, tPos.y + 4, tPos.z)
        local sMdl = sNode:CreateComponent("StaticModel")
        sMdl:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        sMdl:SetMaterial(makeGlow(Color(0.8, 0.9, 1.0, 1.0), 6.0))
        sNode.scale = Vector3(0.12, 4.0, 0.12)

        local sl = sNode:CreateComponent("Light")
        sl.lightType = LIGHT_POINT
        sl.castShadows = false
        sl.range = 8.0
        sl.color = Color(0.7, 0.8, 1.0)
        sl.brightness = 6.0

        table.insert(activeEffects_, {
            type = "lightning_bolt",
            node = sNode,
            life = 0.2 + i * 0.08,
        })

        -- 落点闪光环
        local glow = scene_:CreateChild("LightningGlow_" .. i)
        glow.position = tPos + Vector3(0, 0.1, 0)
        local gm = glow:CreateComponent("StaticModel")
        gm:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
        gm:SetMaterial(makeGlow(Color(0.9, 0.95, 1.0, 1.0), 3.0))
        glow.scale = Vector3(0.8, 0.1, 0.8)

        table.insert(activeEffects_, {
            type = "lightning_glow",
            node = glow,
            life = 0.3 + i * 0.1,
            maxLife = 0.3 + i * 0.1,
            endScale = 2.5,
        })
    end
    print("[SkillSystem] 雷暴释放！命中 " .. hitCount .. " 次")
end

--- 火焰风暴：持续灼烧 + 旋转火环 + 火柱
SKILL_EFFECTS["fireStorm"] = function(skillCfg)
    local playerPos = getPlayerPos_()
    local damage = getScaledDamage(skillCfg.damage)
    local range = getScaledRange(skillCfg.range) * getAreaMult()

    -- 首次伤害
    EnemyManager.AOEDamage(playerPos, range, damage)

    -- 设置持续伤害状态（快照当前加成值）
    fireStormState_ = {
        timer = skillCfg.duration,
        tickTimer = skillCfg.duration / skillCfg.ticks,
        tickInterval = skillCfg.duration / skillCfg.ticks,
        range = range,
        damage = damage,
        ticksRemaining = skillCfg.ticks - 1,
    }

    -- 火焰旋风环（持续可见）
    local fireRing = scene_:CreateChild("FireStormRing")
    fireRing.position = playerPos + Vector3(0, 0.3, 0)
    local rm = fireRing:CreateComponent("StaticModel")
    rm:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
    rm:SetMaterial(makeGlow(Color(1.0, 0.4, 0.1, 1.0), 5.0))
    local rs = range * 0.8
    fireRing.scale = Vector3(rs, 0.4, rs)

    local fl = fireRing:CreateComponent("Light")
    fl.lightType = LIGHT_POINT
    fl.castShadows = false
    fl.range = range + 3
    fl.color = Color(1.0, 0.5, 0.1)
    fl.brightness = 4.0

    table.insert(activeEffects_, {
        type = "fire_ring_spin",
        node = fireRing,
        life = skillCfg.duration,
        maxLife = skillCfg.duration,
    })

    -- 多根火焰柱围绕
    for i = 1, 6 do
        local angle = (i / 6) * 6.28
        local r = range * 0.7
        local pillar = scene_:CreateChild("FirePillar" .. i)
        pillar.position = playerPos + Vector3(math.cos(angle) * r, 0, math.sin(angle) * r)
        local pm = pillar:CreateComponent("StaticModel")
        pm:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        pm:SetMaterial(makeGlow(Color(1.0, 0.6, 0.0, 1.0), 4.0))
        pillar.scale = Vector3(0.2, 2.5, 0.2)

        local plight = pillar:CreateComponent("Light")
        plight.lightType = LIGHT_POINT
        plight.castShadows = false
        plight.range = 3.0
        plight.color = Color(1.0, 0.3, 0.0)
        plight.brightness = 2.0

        table.insert(activeEffects_, {
            type = "fire_pillar",
            node = pillar,
            life = skillCfg.duration * 0.8,
            maxLife = skillCfg.duration * 0.8,
            centerX = playerPos.x,
            centerZ = playerPos.z,
            angle = angle,
            radius = r,
            spinSpeed = 2.0,
        })
    end

    print("[SkillSystem] 火焰风暴释放！持续 " .. skillCfg.duration .. "s")
end

--- 暗影牵引：拉拽敌人 + 紫色漩涡 + 黑洞特效
SKILL_EFFECTS["voidPull"] = function(skillCfg)
    local playerPos = getPlayerPos_()
    local damage = getScaledDamage(skillCfg.damage)
    local range = getScaledRange(skillCfg.range) * getAreaMult()

    -- 伤害
    EnemyManager.AOEDamage(playerPos, range, damage)

    -- 拉拽范围内敌人
    local enemies = EnemyManager.GetAllEnemies()
    for id, e in pairs(enemies) do
        local dx = e.node.position.x - playerPos.x
        local dz = e.node.position.z - playerPos.z
        local dist = math.sqrt(dx * dx + dz * dz)
        if dist <= range and dist > 1.0 then
            -- 将敌人拉向玩家
            local pullDist = math.min(dist - 1.0, skillCfg.pullStrength)
            local dirX = -dx / dist * pullDist
            local dirZ = -dz / dist * pullDist
            local newPos = e.node.position + Vector3(dirX, 0, dirZ)
            e.node.position = newPos
        end
    end

    -- 紫色漩涡球
    local vortex = scene_:CreateChild("VoidVortex")
    vortex.position = playerPos + Vector3(0, 1.0, 0)
    local vm = vortex:CreateComponent("StaticModel")
    vm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    vm:SetMaterial(makeGlow(Color(0.5, 0.1, 0.8, 1.0), 5.0))
    vortex.scale = Vector3(1.5, 1.5, 1.5)

    local vl = vortex:CreateComponent("Light")
    vl.lightType = LIGHT_POINT
    vl.castShadows = false
    vl.range = 10.0
    vl.color = Color(0.6, 0.2, 1.0)
    vl.brightness = 5.0

    table.insert(activeEffects_, {
        type = "vortex_shrink",
        node = vortex,
        life = 0.8,
        maxLife = 0.8,
        startScale = range,
    })

    -- 吸引线/射线特效（指向玩家的光线）
    for i = 1, 12 do
        local angle = (i / 12) * 6.28
        local r = range * 0.9
        local ray = scene_:CreateChild("VoidRay" .. i)
        local sx = playerPos.x + math.cos(angle) * r
        local sz = playerPos.z + math.sin(angle) * r
        local mid = Vector3((sx + playerPos.x) / 2, playerPos.y + 0.5, (sz + playerPos.z) / 2)
        ray.position = mid
        local rm = ray:CreateComponent("StaticModel")
        rm:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        rm:SetMaterial(makeGlow(Color(0.7, 0.3, 1.0, 1.0), 3.0))
        -- 计算朝向和长度
        local len = r * 0.5
        ray.scale = Vector3(0.04, len, 0.04)
        ray.rotation = Quaternion(angle * 180 / 3.14159 + 90, Vector3.UP) * Quaternion(90, Vector3.RIGHT)

        table.insert(activeEffects_, {
            type = "void_ray",
            node = ray,
            life = 0.5,
        })
    end

    print("[SkillSystem] 暗影牵引释放！伤害: " .. damage .. " 范围: " .. string.format("%.1f", range) .. "m")
end

--- 治愈光环：回血 + 绿色光柱 + 护盾
SKILL_EFFECTS["healAura"] = function(skillCfg)
    local playerPos = getPlayerPos_()

    -- 治愈
    local maxHP = PlayerHealth.GetMaxHP()
    local healAmount = math.floor(maxHP * skillCfg.healPercent)
    PlayerHealth.Heal(healAmount)

    -- 护盾
    PlayerHealth.SetShielded(true)
    shieldTimer_ = skillCfg.shieldDuration

    -- 绿色治愈光柱
    local pillar = scene_:CreateChild("HealPillar")
    pillar.position = playerPos
    local pm = pillar:CreateComponent("StaticModel")
    pm:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    pm:SetMaterial(makeGlow(Color(0.2, 1.0, 0.4, 1.0), 4.0))
    pillar.scale = Vector3(1.0, 6.0, 1.0)

    local pl = pillar:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = 12.0
    pl.color = Color(0.3, 1.0, 0.4)
    pl.brightness = 5.0

    table.insert(activeEffects_, {
        type = "heal_pillar",
        node = pillar,
        life = 1.2,
        maxLife = 1.2,
    })

    -- 上升光圈
    for i = 1, 4 do
        local ring = scene_:CreateChild("HealRing" .. i)
        ring.position = playerPos + Vector3(0, 0.5 * i, 0)
        local rm = ring:CreateComponent("StaticModel")
        rm:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
        rm:SetMaterial(makeGlow(Color(0.3, 1.0, 0.5, 1.0), 3.0))
        ring.scale = Vector3(1.2, 0.2, 1.2)

        table.insert(activeEffects_, {
            type = "heal_ring_rise",
            node = ring,
            life = 1.0 + i * 0.2,
            maxLife = 1.0 + i * 0.2,
            startY = playerPos.y + 0.5 * i,
            riseSpeed = 2.0,
        })
    end

    -- 护盾球（半透明绿色球体围绕玩家）
    local shield = scene_:CreateChild("ShieldSphere")
    shield.position = playerPos + Vector3(0, 1.0, 0)
    local sm = shield:CreateComponent("StaticModel")
    sm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    sm:SetMaterial(makeAlpha(Color(0.2, 0.9, 0.3, 0.1)))
    shield.scale = Vector3(2.5, 2.5, 2.5)

    table.insert(activeEffects_, {
        type = "shield_sphere",
        node = shield,
        life = skillCfg.shieldDuration,
    })

    print("[SkillSystem] 治愈光环释放！回复: " .. healAmount .. " HP, 护盾: " .. skillCfg.shieldDuration .. "s")
end

-- ============================================================================
-- 新增 6 个技能
-- ============================================================================

--- 烈焰斩：前方扇形高伤害 + 弧形火焰特效
SKILL_EFFECTS["flameSlash"] = function(skillCfg)
    local playerPos = getPlayerPos_()
    local damage = getScaledDamage(skillCfg.damage)
    local range = getScaledRange(skillCfg.range) * getAreaMult()
    local halfAngle = (skillCfg.angle or 90) / 2

    -- 获取玩家朝向
    local camNode = getCameraNode_()
    local forward = camNode and camNode.direction or Vector3.FORWARD
    local fwdAngle = math.atan(forward.x, forward.z)

    -- 扇形范围内敌人
    local enemies = EnemyManager.GetAllEnemies()
    local hitCount = 0
    for id, e in pairs(enemies) do
        local dx = e.node.position.x - playerPos.x
        local dz = e.node.position.z - playerPos.z
        local dist = math.sqrt(dx * dx + dz * dz)
        if dist <= range then
            local enemyAngle = math.atan(dx, dz)
            local diff = math.abs(enemyAngle - fwdAngle)
            if diff > math.pi then diff = 2 * math.pi - diff end
            if diff <= math.rad(halfAngle) then
                EnemyManager.DamageEnemy(id, damage)
                hitCount = hitCount + 1
            end
        end
    end

    -- 弧形火焰特效
    for i = 1, 5 do
        local a = fwdAngle + math.rad(-halfAngle + (i - 1) * skillCfg.angle / 4)
        local dist = range * 0.6
        local fx = scene_:CreateChild("FlameSlash_" .. i)
        fx.position = playerPos + Vector3(math.sin(a) * dist, 0.5, math.cos(a) * dist)
        local fm = fx:CreateComponent("StaticModel")
        fm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        fm:SetMaterial(makeGlow(Color(1.0, 0.5, 0.0, 1.0), 5.0))
        fx.scale = Vector3(0.3, 1.5, 0.3)

        table.insert(activeEffects_, {
            type = "crystal_fade",
            node = fx,
            life = 0.5 + i * 0.05,
        })
    end

    -- 地面弧形
    local arc = scene_:CreateChild("FlameArc")
    arc.position = playerPos + Vector3(0, 0.1, 0)
    local am = arc:CreateComponent("StaticModel")
    am:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
    am:SetMaterial(makeGlow(Color(1.0, 0.3, 0.0, 1.0), 4.0))
    local arcS = range * 0.8
    arc.scale = Vector3(arcS, 0.15, arcS)

    local al = arc:CreateComponent("Light")
    al.lightType = LIGHT_POINT
    al.castShadows = false
    al.range = range
    al.color = Color(1.0, 0.4, 0.0)
    al.brightness = 4.0

    table.insert(activeEffects_, {
        type = "shockwave_expand",
        node = arc,
        life = 0.4,
        maxLife = 0.4,
        endScale = range * 1.2,
    })

    print("[SkillSystem] 烈焰斩释放！伤害: " .. damage .. " 命中: " .. hitCount)
end

--- 寒冰护甲：减伤 + 冰晶球环绕特效
SKILL_EFFECTS["iceArmor"] = function(skillCfg)
    local playerPos = getPlayerPos_()
    local reflectDmg = getScaledDamage(skillCfg.reflectDamage)

    -- 设置减伤状态
    iceArmorState_ = {
        timer = skillCfg.duration,
        damageReduction = skillCfg.damageReduction,
        reflectDamage = reflectDmg,
    }
    PlayerHealth.SetShielded(true)

    -- 冰晶环绕特效
    for i = 1, 6 do
        local angle = (i / 6) * 6.28
        local crystal = scene_:CreateChild("IceArmorCrystal_" .. i)
        crystal.position = playerPos + Vector3(math.cos(angle) * 1.5, 1.0, math.sin(angle) * 1.5)
        local cm = crystal:CreateComponent("StaticModel")
        cm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        cm:SetMaterial(makeGlow(Color(0.5, 0.8, 1.0, 1.0), 3.0))
        crystal.scale = Vector3(0.15, 0.3, 0.15)
        crystal.rotation = Quaternion(45, Vector3(1, 0, 1):Normalized())

        table.insert(activeEffects_, {
            type = "fire_pillar",
            node = crystal,
            life = skillCfg.duration,
            maxLife = skillCfg.duration,
            centerX = playerPos.x,
            centerZ = playerPos.z,
            angle = angle,
            radius = 1.5,
            spinSpeed = 3.0,
        })
    end

    -- 冰霜光球
    local shield = scene_:CreateChild("IceArmorShield")
    shield.position = playerPos + Vector3(0, 1.0, 0)
    local sm = shield:CreateComponent("StaticModel")
    sm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    sm:SetMaterial(makeAlpha(Color(0.4, 0.7, 1.0, 0.08)))
    shield.scale = Vector3(2.8, 2.8, 2.8)

    table.insert(activeEffects_, {
        type = "shield_sphere",
        node = shield,
        life = skillCfg.duration,
    })

    print("[SkillSystem] 寒冰护甲激活！减伤: " .. (skillCfg.damageReduction * 100) .. "% 反弹: " .. reflectDmg)
end

--- 连锁闪电：弹跳链式伤害
SKILL_EFFECTS["chainLightning"] = function(skillCfg)
    local playerPos = getPlayerPos_()
    local damage = getScaledDamage(skillCfg.damage)
    local bounceRange = getScaledRange(skillCfg.bounceRange)

    -- 查找最近的第一个目标
    local enemies = EnemyManager.GetAllEnemies()
    local camNode = getCameraNode_()
    local forward = camNode and camNode.direction or Vector3.FORWARD

    -- 从玩家前方找起始目标
    local bestId, bestDist = nil, 999
    for id, e in pairs(enemies) do
        local dx = e.node.position.x - playerPos.x
        local dz = e.node.position.z - playerPos.z
        local dist = math.sqrt(dx * dx + dz * dz)
        if dist <= bounceRange and dist < bestDist then
            bestId = id
            bestDist = dist
        end
    end

    if not bestId then
        print("[SkillSystem] 连锁闪电：无目标")
        return
    end

    -- 链式弹跳
    local hitIds = {}
    local currentId = bestId
    local currentDamage = damage
    local prevPos = playerPos
    local totalHits = 0

    for bounce = 1, skillCfg.bounces do
        local enemy = enemies[currentId]
        if not enemy then break end

        EnemyManager.DamageEnemy(currentId, math.floor(currentDamage))
        hitIds[currentId] = true
        totalHits = totalHits + 1

        -- 闪电连线特效
        local ePos = enemy.node.position
        local midPt = Vector3((prevPos.x + ePos.x) / 2, math.max(prevPos.y, ePos.y) + 1.5, (prevPos.z + ePos.z) / 2)
        local bolt = scene_:CreateChild("ChainBolt_" .. bounce)
        bolt.position = midPt
        local bm = bolt:CreateComponent("StaticModel")
        bm:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        bm:SetMaterial(makeGlow(Color(0.6, 0.8, 1.0, 1.0), 5.0))
        local len = math.sqrt((ePos.x - prevPos.x) ^ 2 + (ePos.z - prevPos.z) ^ 2) * 0.5
        bolt.scale = Vector3(0.06, len, 0.06)

        local dx = ePos.x - prevPos.x
        local dz = ePos.z - prevPos.z
        local angle = math.atan(dx, dz) * 180 / math.pi
        bolt.rotation = Quaternion(angle, Vector3.UP) * Quaternion(90, Vector3.RIGHT)

        -- 击中点闪光
        local glow = scene_:CreateChild("ChainGlow_" .. bounce)
        glow.position = ePos + Vector3(0, 0.5, 0)
        local gl = glow:CreateComponent("Light")
        gl.lightType = LIGHT_POINT
        gl.castShadows = false
        gl.range = 4.0
        gl.color = Color(0.6, 0.8, 1.0)
        gl.brightness = 5.0

        table.insert(activeEffects_, {
            type = "lightning_bolt",
            node = bolt,
            life = 0.3 + bounce * 0.05,
        })
        table.insert(activeEffects_, {
            type = "lightning_bolt",
            node = glow,
            life = 0.2 + bounce * 0.05,
        })

        -- 寻找下一个弹跳目标
        prevPos = ePos
        currentDamage = currentDamage * skillCfg.decayRate

        local nextId, nextDist = nil, 999
        for id, e in pairs(enemies) do
            if not hitIds[id] then
                local ddx = e.node.position.x - ePos.x
                local ddz = e.node.position.z - ePos.z
                local d = math.sqrt(ddx * ddx + ddz * ddz)
                if d <= bounceRange and d < nextDist then
                    nextId = id
                    nextDist = d
                end
            end
        end
        if not nextId then break end
        currentId = nextId
    end

    print("[SkillSystem] 连锁闪电释放！弹跳: " .. totalHits .. " 次")
end

--- 大地震击：延迟爆发 + 裂缝特效
SKILL_EFFECTS["earthquakeSlam"] = function(skillCfg)
    local playerPos = getPlayerPos_()
    local damage = getScaledDamage(skillCfg.damage)
    local range = getScaledRange(skillCfg.range) * getAreaMult()

    -- 设置延迟爆发
    earthquakeState_ = {
        timer = skillCfg.delay,
        pos = Vector3(playerPos.x, playerPos.y, playerPos.z),
        damage = damage,
        range = range,
    }

    -- 预警环（蓄力阶段）
    local warn = scene_:CreateChild("EQWarn")
    warn.position = playerPos + Vector3(0, 0.05, 0)
    local wm = warn:CreateComponent("StaticModel")
    wm:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
    wm:SetMaterial(makeAlpha(Color(1.0, 0.5, 0.2, 0.2)))
    local ws = range * 0.5
    warn.scale = Vector3(ws, 0.1, ws)

    table.insert(activeEffects_, {
        type = "shockwave_expand",
        node = warn,
        life = skillCfg.delay,
        maxLife = skillCfg.delay,
        endScale = range * 2,
    })

    -- 蓄力地面裂纹
    for i = 1, 4 do
        local a = (i / 4) * 6.28
        local crack = scene_:CreateChild("EQCrack_" .. i)
        crack.position = playerPos + Vector3(math.cos(a) * 1.0, 0.1, math.sin(a) * 1.0)
        local cm = crack:CreateComponent("StaticModel")
        cm:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        cm:SetMaterial(makeGlow(Color(1.0, 0.6, 0.2, 1.0), 3.0))
        crack.scale = Vector3(0.1, 0.05, range * 0.4)
        crack.rotation = Quaternion(a * 180 / math.pi, Vector3.UP)

        table.insert(activeEffects_, {
            type = "crystal_fade",
            node = crack,
            life = skillCfg.delay + 0.5,
        })
    end

    print("[SkillSystem] 大地震击蓄力！" .. string.format("%.1f", skillCfg.delay) .. "s 后爆发")
end

--- 暗影分身：召唤分身自动攻击
SKILL_EFFECTS["shadowClone"] = function(skillCfg)
    local playerPos = getPlayerPos_()
    local cloneDamage = getScaledDamage(skillCfg.cloneDamage)
    local cloneCount = skillCfg.cloneCount + math.floor(LevelSystem.GetAttackCountBonus() * 0.5)

    -- 清理旧分身
    if shadowCloneState_ then
        for _, c in ipairs(shadowCloneState_.clones) do
            if c then c:Remove() end
        end
    end

    local clones = {}
    for i = 1, cloneCount do
        local angle = (i / cloneCount) * 6.28
        local clone = scene_:CreateChild("ShadowClone_" .. i)
        clone.position = playerPos + Vector3(math.cos(angle) * 2.0, 0, math.sin(angle) * 2.0)

        -- 半透明暗影人形
        local body = clone:CreateChild("Body")
        body.position = Vector3(0, 0.7, 0)
        local bm = body:CreateComponent("StaticModel")
        bm:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        bm:SetMaterial(makeAlpha(Color(0.2, 0.1, 0.4, 0.35)))
        body.scale = Vector3(0.4, 0.7, 0.4)

        local head = clone:CreateChild("Head")
        head.position = Vector3(0, 1.5, 0)
        local hm = head:CreateComponent("StaticModel")
        hm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        hm:SetMaterial(makeAlpha(Color(0.3, 0.1, 0.5, 0.4)))
        head.scale = Vector3(0.3, 0.3, 0.3)

        -- 发光眼睛
        local eye = clone:CreateChild("Eye")
        eye.position = Vector3(0, 1.5, 0.12)
        local el = eye:CreateComponent("Light")
        el.lightType = LIGHT_POINT
        el.castShadows = false
        el.range = 2.0
        el.color = Color(0.6, 0.2, 1.0)
        el.brightness = 3.0

        table.insert(clones, clone)
    end

    shadowCloneState_ = {
        timer = skillCfg.duration,
        attackTimer = 0,
        interval = skillCfg.attackInterval,
        damage = cloneDamage,
        clones = clones,
        attackRange = 8.0,
    }

    print("[SkillSystem] 暗影分身召唤！数量: " .. cloneCount .. " 伤害: " .. cloneDamage)
end

--- 生命汲取：AOE 伤害 + 吸血
SKILL_EFFECTS["lifeDrain"] = function(skillCfg)
    local playerPos = getPlayerPos_()
    local damage = getScaledDamage(skillCfg.damage)
    local range = getScaledRange(skillCfg.range) * getAreaMult()

    -- AOE 伤害
    local enemies = EnemyManager.GetAllEnemies()
    local hitCount = 0
    for id, e in pairs(enemies) do
        local dx = e.node.position.x - playerPos.x
        local dz = e.node.position.z - playerPos.z
        if math.sqrt(dx * dx + dz * dz) <= range then
            EnemyManager.DamageEnemy(id, damage)
            hitCount = hitCount + 1
        end
    end

    -- 吸血回复
    local healAmount = math.floor(hitCount * damage * skillCfg.healRatio)
    if healAmount > 0 then
        PlayerHealth.Heal(healAmount)
    end

    -- 暗紫色能量涌动特效
    local vortex = scene_:CreateChild("LifeDrainVortex")
    vortex.position = playerPos + Vector3(0, 0.3, 0)
    local vm = vortex:CreateComponent("StaticModel")
    vm:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
    vm:SetMaterial(makeGlow(Color(0.6, 0.1, 0.8, 1.0), 4.0))
    local vs = range * 0.5
    vortex.scale = Vector3(vs, 0.3, vs)

    local vl = vortex:CreateComponent("Light")
    vl.lightType = LIGHT_POINT
    vl.castShadows = false
    vl.range = range
    vl.color = Color(0.5, 0.1, 0.7)
    vl.brightness = 4.0

    table.insert(activeEffects_, {
        type = "vortex_shrink",
        node = vortex,
        life = 0.8,
        maxLife = 0.8,
        startScale = range,
    })

    -- 吸收光线（从敌人位置到玩家）
    for id, e in pairs(enemies) do
        local dx = e.node.position.x - playerPos.x
        local dz = e.node.position.z - playerPos.z
        if math.sqrt(dx * dx + dz * dz) <= range then
            local ePos = e.node.position
            local mid = Vector3((ePos.x + playerPos.x) / 2, playerPos.y + 1.0, (ePos.z + playerPos.z) / 2)
            local ray = scene_:CreateChild("DrainRay")
            ray.position = mid
            local rm = ray:CreateComponent("StaticModel")
            rm:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
            rm:SetMaterial(makeGlow(Color(0.8, 0.2, 1.0, 1.0), 3.0))
            local len = math.sqrt((ePos.x - playerPos.x) ^ 2 + (ePos.z - playerPos.z) ^ 2) * 0.5
            ray.scale = Vector3(0.05, math.max(0.1, len), 0.05)

            local angle = math.atan(dx, dz) * 180 / math.pi
            ray.rotation = Quaternion(angle, Vector3.UP) * Quaternion(90, Vector3.RIGHT)

            table.insert(activeEffects_, {
                type = "void_ray",
                node = ray,
                life = 0.6,
            })
        end
    end

    -- 玩家身上治愈光芒
    if healAmount > 0 then
        local glow = scene_:CreateChild("DrainHealGlow")
        glow.position = playerPos + Vector3(0, 1.0, 0)
        local gm = glow:CreateComponent("StaticModel")
        gm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        gm:SetMaterial(makeGlow(Color(0.3, 1.0, 0.4, 1.0), 3.0))
        glow.scale = Vector3(0.8, 0.8, 0.8)

        table.insert(activeEffects_, {
            type = "heal_pillar",
            node = glow,
            life = 0.6,
            maxLife = 0.6,
        })
    end

    print("[SkillSystem] 生命汲取释放！伤害: " .. damage .. " 命中: " .. hitCount .. " 回复: " .. healAmount)
end

-- ============================================================================
-- 特效更新
-- ============================================================================

local function updateEffects(dt)
    local toRemove = {}
    for i, fx in ipairs(activeEffects_) do
        fx.life = fx.life - dt

        if fx.type == "shockwave_expand" then
            local pct = 1.0 - fx.life / fx.maxLife
            local s = 0.5 + (fx.endScale - 0.5) * pct
            fx.node.scale = Vector3(s, math.max(0.05, fx.node.scale.y * 0.97), s)
            local light = fx.node:GetComponent("Light")
            if light then
                light.brightness = 4.0 * (fx.life / fx.maxLife)
            end

        elseif fx.type == "freeze_flash" then
            local pct = fx.life / fx.maxLife
            local scale = fx.node.scale.x * (0.98 + 0.02 * pct)
            fx.node.scale = Vector3(scale, scale, scale)
            local light = fx.node:GetComponent("Light")
            if light then light.brightness = 5.0 * pct end

        elseif fx.type == "crystal_fade" then
            -- 冰晶慢慢下落并消失
            fx.node.position = fx.node.position + Vector3(0, -0.5 * dt, 0)
            fx.node.rotation = fx.node.rotation * Quaternion(dt * 45, Vector3.UP)

        elseif fx.type == "lightning_bolt" then
            -- 闪电闪烁效果
            local flicker = math.random() > 0.3
            local light = fx.node:GetComponent("Light")
            if light then light.brightness = flicker and 6.0 or 2.0 end

        elseif fx.type == "lightning_glow" then
            -- 地面电弧扩散
            local pct = 1.0 - fx.life / fx.maxLife
            local s = 0.8 + (fx.endScale - 0.8) * pct
            fx.node.scale = Vector3(s, 0.1, s)

        elseif fx.type == "fire_ring_spin" then
            -- 火环旋转 + 渐淡
            fx.node.rotation = fx.node.rotation * Quaternion(dt * 120, Vector3.UP)
            local pct = fx.life / fx.maxLife
            local light = fx.node:GetComponent("Light")
            if light then light.brightness = 4.0 * pct end

        elseif fx.type == "fire_pillar" then
            -- 火柱围绕旋转
            fx.angle = fx.angle + fx.spinSpeed * dt
            local nx = fx.centerX + math.cos(fx.angle) * fx.radius
            local nz = fx.centerZ + math.sin(fx.angle) * fx.radius
            fx.node.position = Vector3(nx, fx.node.position.y, nz)
            -- 高度波动
            local baseScale = 2.5 * (fx.life / fx.maxLife)
            fx.node.scale = Vector3(0.2, baseScale, 0.2)

        elseif fx.type == "vortex_shrink" then
            -- 漩涡从大到小收缩
            local pct = fx.life / fx.maxLife
            local s = fx.startScale * pct
            fx.node.scale = Vector3(s, s, s)
            fx.node.rotation = fx.node.rotation * Quaternion(dt * 300, Vector3.UP)
            local light = fx.node:GetComponent("Light")
            if light then light.brightness = 5.0 * pct end

        elseif fx.type == "void_ray" then
            -- 射线快速消失
            local s = fx.node.scale
            fx.node.scale = Vector3(s.x * 0.92, s.y, s.z * 0.92)

        elseif fx.type == "heal_pillar" then
            -- 光柱上升并消散
            local pct = fx.life / fx.maxLife
            fx.node.position = fx.node.position + Vector3(0, dt * 3, 0)
            fx.node.scale = Vector3(1.0 * pct, 6.0, 1.0 * pct)
            local light = fx.node:GetComponent("Light")
            if light then light.brightness = 5.0 * pct end

        elseif fx.type == "heal_ring_rise" then
            -- 光圈上升并扩大
            fx.node.position = fx.node.position + Vector3(0, fx.riseSpeed * dt, 0)
            local pct = fx.life / fx.maxLife
            local s = 1.2 + (1.0 - pct) * 1.5
            fx.node.scale = Vector3(s, 0.15 * pct, s)

        elseif fx.type == "shield_sphere" then
            -- 护盾球跟随玩家位置
            local pp = getPlayerPos_()
            fx.node.position = pp + Vector3(0, 1.0, 0)
            -- 呼吸脉动
            local pulse = 2.5 + math.sin(fx.life * 6) * 0.15
            fx.node.scale = Vector3(pulse, pulse, pulse)
        end

        if fx.life <= 0 then
            table.insert(toRemove, i)
        end
    end

    for i = #toRemove, 1, -1 do
        local idx = toRemove[i]
        if activeEffects_[idx].node then
            activeEffects_[idx].node:Remove()
        end
        table.remove(activeEffects_, idx)
    end
end

-- ============================================================================
-- 技能释放
-- ============================================================================

--- 尝试使用技能
---@param skillId string
---@return boolean
function SkillSystem.TryUseSkill(skillId)
    -- 委托 LevelSystem 检查解锁和冷却
    if not LevelSystem.UseSkill(skillId) then return false end

    -- 查找技能配置
    local skillCfg = nil
    for _, s in ipairs(GameConfig.LevelSkills) do
        if s.id == skillId then skillCfg = s; break end
    end
    if not skillCfg then return false end

    -- 用加成后的冷却覆盖 LevelSystem 设置的原始冷却
    local scaledCD = getScaledCooldown(skillCfg.cooldown)
    LevelSystem.SetSkillCooldown(skillId, scaledCD)

    -- 执行技能特效
    local effectFn = SKILL_EFFECTS[skillId]
    if effectFn then effectFn(skillCfg) end

    return true
end

-- ============================================================================
-- HUD 查询接口
-- ============================================================================

--- 获取技能槽位信息（供 HUD 渲染）
---@return table[] { slotIndex, skillId, unlocked, cooldown, maxCooldown, icon, name, keyLabel }
function SkillSystem.GetSlotInfo()
    local slots = {}
    for i, skillId in ipairs(SKILL_ORDER) do
        local unlocked = LevelSystem.HasSkill(skillId)
        local cooldown = LevelSystem.GetSkillCooldown(skillId)
        local skillCfg = nil
        for _, s in ipairs(GameConfig.LevelSkills) do
            if s.id == skillId then skillCfg = s; break end
        end
        local maxCD = skillCfg and getScaledCooldown(skillCfg.cooldown) or 0
        table.insert(slots, {
            slotIndex = i,
            skillId = skillId,
            unlocked = unlocked,
            cooldown = cooldown,
            maxCooldown = maxCD,
            icon = skillCfg and skillCfg.icon or "?",
            name = skillCfg and skillCfg.name or skillId,
            keyLabel = tostring(i),
        })
    end
    return slots
end

--- 获取技能总数
---@return number
function SkillSystem.GetSkillCount()
    return #SKILL_ORDER
end

--- 获取寒冰护甲减伤率（0 表示无护甲）
---@return number
function SkillSystem.GetIceArmorReduction()
    if iceArmorState_ then
        return iceArmorState_.damageReduction
    end
    return 0
end

--- 获取寒冰护甲反弹伤害（0 表示无护甲）
---@return number
function SkillSystem.GetIceArmorReflect()
    if iceArmorState_ then
        return iceArmorState_.reflectDamage
    end
    return 0
end

-- ============================================================================
-- 公共接口
-- ============================================================================

---@param scene Scene
---@param getPos function 返回玩家位置
---@param getCam function 返回相机节点
function SkillSystem.Init(scene, getPos, getCam)
    scene_ = scene
    getPlayerPos_ = getPos
    getCameraNode_ = getCam
    activeEffects_ = {}
    fireStormState_ = nil
    shieldTimer_ = 0
    iceArmorState_ = nil
    earthquakeState_ = nil
    shadowCloneState_ = nil
    print("[SkillSystem] 初始化完成，技能键: 1-12")
end

---@param dt number
function SkillSystem.Update(dt)
    if not scene_ then return end
    if GameManager.GetState() ~= GameConfig.States.PLAYING then return end

    -- 检测技能按键 1-6
    for slotIndex, keyCode in ipairs(SKILL_KEYS) do
        local mobilePressed = (slotIndex <= 4) and MobileControls.WasPressed("skill" .. slotIndex) or false
        if input:GetKeyPress(keyCode) or mobilePressed then
            SkillSystem.TryUseSkill(SKILL_ORDER[slotIndex])
        end
    end

    -- 火焰风暴持续伤害
    if fireStormState_ then
        fireStormState_.timer = fireStormState_.timer - dt
        fireStormState_.tickTimer = fireStormState_.tickTimer - dt

        if fireStormState_.tickTimer <= 0 and fireStormState_.ticksRemaining > 0 then
            local playerPos = getPlayerPos_()
            EnemyManager.AOEDamage(playerPos, fireStormState_.range, fireStormState_.damage)
            fireStormState_.ticksRemaining = fireStormState_.ticksRemaining - 1
            fireStormState_.tickTimer = fireStormState_.tickInterval
        end

        if fireStormState_.timer <= 0 then
            fireStormState_ = nil
        end
    end

    -- 护盾计时
    if shieldTimer_ > 0 then
        shieldTimer_ = shieldTimer_ - dt
        if shieldTimer_ <= 0 then
            PlayerHealth.SetShielded(false)
            shieldTimer_ = 0
        end
    end

    -- 寒冰护甲计时
    if iceArmorState_ then
        iceArmorState_.timer = iceArmorState_.timer - dt
        if iceArmorState_.timer <= 0 then
            PlayerHealth.SetShielded(false)
            iceArmorState_ = nil
        end
    end

    -- 大地震击延迟爆发
    if earthquakeState_ then
        earthquakeState_.timer = earthquakeState_.timer - dt
        if earthquakeState_.timer <= 0 then
            -- 爆发！
            EnemyManager.AOEDamage(earthquakeState_.pos, earthquakeState_.range, earthquakeState_.damage)

            -- 爆发冲击环特效
            local boom = scene_:CreateChild("EQBoom")
            boom.position = earthquakeState_.pos + Vector3(0, 0.2, 0)
            local bm = boom:CreateComponent("StaticModel")
            bm:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
            bm:SetMaterial(makeGlow(Color(1.0, 0.4, 0.1, 1.0), 6.0))
            boom.scale = Vector3(1.0, 0.3, 1.0)

            local bl = boom:CreateComponent("Light")
            bl.lightType = LIGHT_POINT
            bl.castShadows = false
            bl.range = earthquakeState_.range + 3
            bl.color = Color(1.0, 0.5, 0.1)
            bl.brightness = 6.0

            table.insert(activeEffects_, {
                type = "shockwave_expand",
                node = boom,
                life = 0.6,
                maxLife = 0.6,
                endScale = earthquakeState_.range * 2,
            })

            print("[SkillSystem] 大地震击爆发！伤害: " .. earthquakeState_.damage .. " 范围: " .. string.format("%.1f", earthquakeState_.range) .. "m")
            earthquakeState_ = nil
        end
    end

    -- 暗影分身自动攻击
    if shadowCloneState_ then
        shadowCloneState_.timer = shadowCloneState_.timer - dt
        shadowCloneState_.attackTimer = shadowCloneState_.attackTimer - dt

        -- 分身跟随玩家
        local playerPos = getPlayerPos_()
        for i, clone in ipairs(shadowCloneState_.clones) do
            if clone then
                local angle = (i / #shadowCloneState_.clones) * 6.28 + time:GetElapsedTime() * 1.5
                local targetPos = playerPos + Vector3(math.cos(angle) * 2.5, 0, math.sin(angle) * 2.5)
                local cur = clone.position
                clone.position = cur + (targetPos - cur) * math.min(1.0, dt * 4.0)
            end
        end

        -- 攻击间隔到达时，每个分身攻击最近的敌人
        if shadowCloneState_.attackTimer <= 0 then
            shadowCloneState_.attackTimer = shadowCloneState_.interval
            local enemies = EnemyManager.GetAllEnemies()
            for _, clone in ipairs(shadowCloneState_.clones) do
                if clone then
                    local bestId, bestDist = nil, shadowCloneState_.attackRange
                    for id, e in pairs(enemies) do
                        local dx = e.node.position.x - clone.position.x
                        local dz = e.node.position.z - clone.position.z
                        local d = math.sqrt(dx * dx + dz * dz)
                        if d < bestDist then
                            bestId = id
                            bestDist = d
                        end
                    end
                    if bestId then
                        EnemyManager.DamageEnemy(bestId, shadowCloneState_.damage)
                        -- 攻击特效
                        local ePos = enemies[bestId].node.position
                        local bolt = scene_:CreateChild("CloneAttack")
                        bolt.position = (clone.position + ePos) * 0.5 + Vector3(0, 1.0, 0)
                        local bm = bolt:CreateComponent("StaticModel")
                        bm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
                        bm:SetMaterial(makeGlow(Color(0.5, 0.2, 0.8, 1.0), 4.0))
                        bolt.scale = Vector3(0.2, 0.2, 0.2)
                        table.insert(activeEffects_, {
                            type = "lightning_bolt",
                            node = bolt,
                            life = 0.2,
                        })
                    end
                end
            end
        end

        -- 超时清理
        if shadowCloneState_.timer <= 0 then
            for _, c in ipairs(shadowCloneState_.clones) do
                if c then c:Remove() end
            end
            shadowCloneState_ = nil
        end
    end

    -- 更新视觉特效
    updateEffects(dt)
end

--- 仅清除活跃特效和持续状态（广告复活用，保留技能解锁）
function SkillSystem.CleanupEffects()
    for _, fx in ipairs(activeEffects_) do
        if fx.node then fx.node:Remove() end
    end
    activeEffects_ = {}
    fireStormState_ = nil
    earthquakeState_ = nil
    if shieldTimer_ > 0 then
        PlayerHealth.SetShielded(false)
    end
    shieldTimer_ = 0
    if iceArmorState_ then
        PlayerHealth.SetShielded(false)
        iceArmorState_ = nil
    end
    if shadowCloneState_ then
        for _, c in ipairs(shadowCloneState_.clones) do
            if c then c:Remove() end
        end
        shadowCloneState_ = nil
    end
end

function SkillSystem.Reset()
    SkillSystem.CleanupEffects()
end

return SkillSystem
