-- ============================================================================
-- EquipmentSystem.lua — 装备系统
-- 区域Boss掉落装备，最多装备2件，提供被动加成 + 触发特效(Proc)
-- ============================================================================

local GameConfig = require("config.GameConfig")
local GameManager = require("core.GameManager")
local PlayerHealth = require("combat.PlayerHealth")

local EquipmentSystem = {}

---@type Scene
local scene_ = nil
local getPlayerPos_ = nil

-- 装备状态
local NUM_EQUIP_SLOTS = 5
local equipped_ = { nil, nil, nil, nil, nil }   -- 5个装备槽

-- Proc 内部冷却（防止同帧多次触发）
local procCooldowns_ = {}        -- { [equipId] = remaining }
local PROC_COOLDOWN = 0.5        -- Proc 最小触发间隔

-- 鬼面狂暴 buff
local demonRageActive_ = false
local demonRageTimer_ = 0
local demonRageMult_ = 1.0

-- 视觉特效节点缓存
local overlayNodes_ = {}

-- 仓库系统引用（词条加成来源，依赖注入避免循环引用）
local InventorySystem_ = nil

-- ============================================================================
-- 初始化 / 重置
-- ============================================================================

---@param scn Scene
---@param getPos function
function EquipmentSystem.Init(scn, getPos)
    scene_ = scn
    getPlayerPos_ = getPos
    equipped_ = {}
    for i = 1, NUM_EQUIP_SLOTS do equipped_[i] = nil end
    procCooldowns_ = {}
    demonRageActive_ = false
    demonRageTimer_ = 0
    demonRageMult_ = 1.0
    overlayNodes_ = {}
    print("[EquipmentSystem] 初始化完成")
end

--- 注入 InventorySystem 引用（由 main.lua 调用）
---@param invSys table
function EquipmentSystem.SetInventorySystem(invSys)
    InventorySystem_ = invSys
end

function EquipmentSystem.Reset()
    equipped_ = {}
    for i = 1, NUM_EQUIP_SLOTS do equipped_[i] = nil end
    procCooldowns_ = {}
    demonRageActive_ = false
    demonRageTimer_ = 0
    demonRageMult_ = 1.0
    -- 清理视觉节点
    for _, n in ipairs(overlayNodes_) do
        if n then n:Remove() end
    end
    overlayNodes_ = {}
    print("[EquipmentSystem] 已重置")
end

-- ============================================================================
-- 装备管理
-- ============================================================================

--- 装备一件道具（自动放入空槽，满则替换第一个）
---@param equipId string
---@return number slot 放入的槽位(1或2)
function EquipmentSystem.Equip(equipId)
    local cfg = GameConfig.Equipment[equipId]
    if not cfg then
        print("[EquipmentSystem] 未知装备: " .. tostring(equipId))
        return 0
    end

    -- 已装备相同的不重复
    for i = 1, NUM_EQUIP_SLOTS do
        if equipped_[i] == equipId then
            print("[EquipmentSystem] 已装备: " .. cfg.name)
            return i
        end
    end

    -- 优先空槽
    for i = 1, NUM_EQUIP_SLOTS do
        if not equipped_[i] then
            equipped_[i] = equipId
            GameManager.SetEquipment(i, equipId)
            print("[EquipmentSystem] 装备到槽" .. i .. ": " .. cfg.name)
            return i
        end
    end

    -- 满了替换第一个
    equipped_[1] = equipId
    GameManager.SetEquipment(1, equipId)
    print("[EquipmentSystem] 替换槽1: " .. cfg.name)
    return 1
end

--- 获取当前已装备列表
---@return table { [1]=equipId|nil, [2]=equipId|nil }
function EquipmentSystem.GetEquipped()
    return equipped_
end

--- 是否已装备某件
---@param equipId string
---@return boolean
function EquipmentSystem.HasEquipped(equipId)
    for i = 1, NUM_EQUIP_SLOTS do
        if equipped_[i] == equipId then return true end
    end
    return false
end

-- ============================================================================
-- 被动加成计算
-- ============================================================================

--- 获取词条加成（内部辅助）
---@param statName string
---@return number
local function getAffixBonus(statName)
    if InventorySystem_ then
        return InventorySystem_.GetTotalAffixBonus(statName)
    end
    return 0
end

--- 最大生命加成
---@return number
function EquipmentSystem.GetMaxHPBonus()
    local bonus = 0
    for i = 1, NUM_EQUIP_SLOTS do
        if equipped_[i] then
            local cfg = GameConfig.Equipment[equipped_[i]]
            if cfg and cfg.passive and cfg.passive.maxHP then
                bonus = bonus + cfg.passive.maxHP
            end
        end
    end
    -- 叠加词条 maxHP 加成
    bonus = bonus + getAffixBonus("maxHP")
    return bonus
end

--- 伤害加成倍率 (1.0 = 无加成)
---@return number
function EquipmentSystem.GetDamageMult()
    local pct = 0
    for i = 1, NUM_EQUIP_SLOTS do
        if equipped_[i] then
            local cfg = GameConfig.Equipment[equipped_[i]]
            if cfg and cfg.passive and cfg.passive.damagePct then
                pct = pct + cfg.passive.damagePct
            end
        end
    end
    -- 叠加词条 damagePct 加成
    pct = pct + getAffixBonus("damagePct")
    -- 叠加鬼面狂暴
    local mult = 1.0 + pct / 100.0
    if demonRageActive_ then
        mult = mult * demonRageMult_
    end
    return mult
end

--- 武器冷却倍率 (含装备攻速加成)
---@return number
function EquipmentSystem.GetCooldownMult()
    local pct = 0
    for i = 1, NUM_EQUIP_SLOTS do
        if equipped_[i] then
            local cfg = GameConfig.Equipment[equipped_[i]]
            if cfg and cfg.passive then
                if cfg.passive.cooldownPct then pct = pct + cfg.passive.cooldownPct end
                if cfg.passive.atkSpdPct then pct = pct + cfg.passive.atkSpdPct end
            end
        end
    end
    -- 叠加词条加成
    pct = pct + getAffixBonus("cooldownPct") + getAffixBonus("atkSpdPct")
    return math.max(0.1, 1.0 - pct / 100.0)
end

--- 移动速度倍率
---@return number
function EquipmentSystem.GetMoveSpeedMult()
    local pct = 0
    for i = 1, NUM_EQUIP_SLOTS do
        if equipped_[i] then
            local cfg = GameConfig.Equipment[equipped_[i]]
            if cfg and cfg.passive and cfg.passive.moveSpdPct then
                pct = pct + cfg.passive.moveSpdPct
            end
        end
    end
    -- 叠加词条 moveSpdPct 加成
    pct = pct + getAffixBonus("moveSpdPct")
    return 1.0 + pct / 100.0
end

--- 攻击范围倍率
---@return number
function EquipmentSystem.GetRangeMult()
    local pct = 0
    for i = 1, NUM_EQUIP_SLOTS do
        if equipped_[i] then
            local cfg = GameConfig.Equipment[equipped_[i]]
            if cfg and cfg.passive and cfg.passive.rangePct then
                pct = pct + cfg.passive.rangePct
            end
        end
    end
    -- 叠加词条 rangePct 加成
    pct = pct + getAffixBonus("rangePct")
    return 1.0 + pct / 100.0
end

-- ============================================================================
-- Proc 触发系统（攻击命中时调用）
-- ============================================================================

--- 攻击命中后的 Proc 触发
---@param targetId string 被击中敌人ID
---@param damage number 本次伤害
---@param hitPos Vector3 命中位置
function EquipmentSystem.OnAttackHit(targetId, damage, hitPos)
    local EnemyManager = require("combat.EnemyManager")

    for i = 1, NUM_EQUIP_SLOTS do
        local eqId = equipped_[i]
        if not eqId then goto continue end

        -- 冷却检测
        if (procCooldowns_[eqId] or 0) > 0 then goto continue end

        local cfg = GameConfig.Equipment[eqId]
        if not cfg or not cfg.proc then goto continue end

        local proc = cfg.proc
        if math.random() > proc.chance then goto continue end

        -- 触发！设置冷却
        procCooldowns_[eqId] = PROC_COOLDOWN

        if proc.type == "lifeSteal" then
            -- 生命汲取
            PlayerHealth.Heal(proc.amount)
            print("[Proc] 生命汲取 +" .. proc.amount)

        elseif proc.type == "shatter" then
            -- 碎裂冲击：以命中点为中心 AOE
            EnemyManager.AOEDamage(hitPos, proc.range, proc.damage)
            print("[Proc] 碎裂冲击 AOE " .. proc.damage)

        elseif proc.type == "slow" then
            -- 减速：设置目标减速标记
            local e = EnemyManager.GetAllEnemies()[targetId]
            if e then
                e.slowTimer = proc.duration
                e.slowPct = proc.slowPct / 100.0
                print("[Proc] 减速 " .. proc.slowPct .. "% " .. proc.duration .. "s")
            end

        elseif proc.type == "burn" then
            -- 灼烧 DOT
            local e = EnemyManager.GetAllEnemies()[targetId]
            if e then
                e.burnTimer = proc.duration
                e.burnDPS = proc.dps
                print("[Proc] 灼烧 " .. proc.dps .. "dps " .. proc.duration .. "s")
            end

        elseif proc.type == "demonRage" then
            -- 鬼面狂暴：增伤 buff
            demonRageActive_ = true
            demonRageTimer_ = proc.duration
            demonRageMult_ = proc.damageMult
            print("[Proc] 鬼面狂暴 x" .. proc.damageMult .. " " .. proc.duration .. "s")
        end

        ::continue::
    end
end

-- ============================================================================
-- 视觉叠层（给武器弹体添加装备发光效果）
-- ============================================================================

--- 获取所有装备的叠层信息
---@return table[] { { color=Color, intensity=number }, ... }
function EquipmentSystem.GetAllOverlays()
    local overlays = {}
    for i = 1, NUM_EQUIP_SLOTS do
        if equipped_[i] then
            local cfg = GameConfig.Equipment[equipped_[i]]
            if cfg then
                table.insert(overlays, {
                    color = cfg.overlayColor,
                    intensity = cfg.overlayIntensity or 1.5,
                })
            end
        end
    end
    return overlays
end

--- 给弹体节点添加装备视觉叠层
---@param projectileNode Node
function EquipmentSystem.ApplyOverlayToNode(projectileNode)
    if not projectileNode then return end
    local overlays = EquipmentSystem.GetAllOverlays()
    for idx, ov in ipairs(overlays) do
        local glowNode = projectileNode:CreateChild("EquipOverlay_" .. idx)
        local mdl = glowNode:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        mdl:SetMaterial(GameConfig.CreateEmissiveMaterial(ov.color, ov.intensity))
        local s = 0.3 + idx * 0.1
        glowNode.scale = Vector3(s, s, s)
        -- 光源
        local pl = glowNode:CreateComponent("Light")
        pl.lightType = LIGHT_POINT
        pl.castShadows = false
        pl.range = 2.0
        pl.color = ov.color
        pl.brightness = ov.intensity
    end
end

-- ============================================================================
-- 更新
-- ============================================================================

---@param dt number
function EquipmentSystem.Update(dt)
    -- Proc 冷却更新
    for id, t in pairs(procCooldowns_) do
        if t > 0 then
            procCooldowns_[id] = math.max(0, t - dt)
        end
    end

    -- 鬼面狂暴 buff 计时
    if demonRageActive_ then
        demonRageTimer_ = demonRageTimer_ - dt
        if demonRageTimer_ <= 0 then
            demonRageActive_ = false
            demonRageMult_ = 1.0
        end
    end
end

--- 是否处于鬼面狂暴状态
---@return boolean
function EquipmentSystem.IsDemonRageActive()
    return demonRageActive_
end

return EquipmentSystem
