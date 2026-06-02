-- ============================================================================
-- MeleeWeaponView.lua — 第一人称近战武器视图
-- 武器模型（内置几何体组合剑）+ 程序化动画状态机 + 攻击判定 hit frame
-- ============================================================================

local GameConfig = require("config.GameConfig")

local MeleeWeaponView = {}

-- ============================================================================
-- 常量
-- ============================================================================

-- 动画状态
local STATE_IDLE     = "IDLE"
local STATE_SWING1   = "SWING_1"
local STATE_SWING2   = "SWING_2"
local STATE_DOWNWARD = "DOWNWARD"
local STATE_RECOVERY = "RECOVERY"

-- 动画时长（秒）
local DURATIONS = {
    [STATE_SWING1]   = 0.18,
    [STATE_SWING2]   = 0.14,
    [STATE_DOWNWARD] = 0.25,
    [STATE_RECOVERY] = 0.22,
}

-- Hit frame 触发时机（归一化 0~1）
local HIT_FRAME_T = {
    [STATE_SWING1]   = 0.65,
    [STATE_DOWNWARD] = 0.65,
}

-- 连招窗口（SWING_1 中 t >= 此值时可输入连招）
local COMBO_WINDOW_T = 0.55

-- 武器静止位姿（相对于 cameraNode_）
local REST_POS = Vector3(0.35, -0.32, 0.50)
local REST_ROT = Quaternion(-10, 15, -5)

-- ============================================================================
-- 关键帧位姿
-- ============================================================================

-- SWING_1: 水平右→左挥砍
local WINDUP_POS  = Vector3(0.42, -0.18, 0.42)
local WINDUP_ROT  = Quaternion(-15, 35, -15)
local SLASH1_POS  = Vector3(-0.08, -0.28, 0.52)
local SLASH1_ROT  = Quaternion(0, -40, 25)

-- SWING_2: 跟随弧
local SLASH2_POS  = Vector3(-0.18, -0.36, 0.44)
local SLASH2_ROT  = Quaternion(5, -55, 30)

-- DOWNWARD: 抬剑→下劈
local RAISE_POS   = Vector3(0.22, 0.15, 0.50)
local RAISE_ROT   = Quaternion(-65, 5, 0)
local CHOP_POS    = Vector3(0.22, -0.42, 0.58)
local CHOP_ROT    = Quaternion(25, 5, 5)

-- ============================================================================
-- 模块状态
-- ============================================================================

---@type Node
local weaponPivot_ = nil    -- 武器根节点（动画目标）
---@type Node
local cameraNode_ = nil     -- 所属的相机节点

local animState_ = STATE_IDLE
local stateTimer_ = 0.0
local time_ = 0.0           -- 全局时间（idle bob 用）
local hitFired_ = false      -- 当前攻击是否已触发伤害
local pendingCombo_ = false  -- 是否队列了连招

local currentPos_ = Vector3(0, 0, 0)
local currentRot_ = Quaternion()

-- 回调
local onHitFrame_ = nil      -- function(weaponId, attackType)
local weaponId_ = nil        -- 当前武器 ID

-- 屏幕震动
local shakeTimer_ = 0.0
local shakeIntensity_ = 0.0

-- slash trail 特效
---@type Scene
local scene_ = nil
local activeTrails_ = {}

-- ============================================================================
-- 缓动函数
-- ============================================================================

local function easeInQuad(t)
    return t * t
end

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
-- 武器模型构建
-- ============================================================================

local function createPart(parent, name, modelName, scaleVec, posVec, material)
    local node = parent:CreateChild(name)
    node.position = posVec
    node:SetScale(scaleVec)
    local mdl = node:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/" .. modelName .. ".mdl"))
    mdl:SetMaterial(material)
    return node
end

--- 构建剑模型
---@param parentNode Node 相机节点
---@param glowColor Color 辉光颜色
---@return Node weaponPivot
local function buildSwordModel(parentNode, glowColor)
    local pivot = parentNode:CreateChild("WeaponPivot")
    pivot.position = REST_POS
    pivot.rotation = REST_ROT

    -- 材质
    local bladeColor = Color(0.75, 0.78, 0.82, 1.0)
    local guardColor = Color(0.55, 0.40, 0.22, 1.0)
    local gripColor  = Color(0.30, 0.18, 0.10, 1.0)
    local edgeColor  = Color(0.90, 0.95, 1.00, 1.0)

    local bladeMat = GameConfig.CreateMaterial(bladeColor, 0.55, 0.6)
    local guardMat = GameConfig.CreateMaterial(guardColor, 0.70, 0.3)
    local gripMat  = GameConfig.CreateMaterial(gripColor,  0.85, 0.0)
    local edgeMat  = GameConfig.CreateEmissiveMaterial(edgeColor, 1.2)
    local glowMat  = GameConfig.CreateEmissiveMaterial(glowColor, 3.0)

    -- 剑身（主体）
    createPart(pivot, "Blade", "Box",
        Vector3(0.06, 0.70, 0.04),
        Vector3(0, 0.35, 0), bladeMat)

    -- 刃边（发光薄层）
    createPart(pivot, "BladeEdge", "Box",
        Vector3(0.02, 0.68, 0.048),
        Vector3(0.025, 0.35, 0), edgeMat)

    -- 剑尖
    createPart(pivot, "BladeTip", "Pyramid",
        Vector3(0.06, 0.12, 0.04),
        Vector3(0, 0.76, 0), bladeMat)

    -- 护手
    createPart(pivot, "Guard", "Box",
        Vector3(0.22, 0.04, 0.08),
        Vector3(0, 0, 0), guardMat)

    -- 握柄
    createPart(pivot, "Grip", "Cylinder",
        Vector3(0.035, 0.20, 0.035),
        Vector3(0, -0.12, 0), gripMat)

    -- 柄底球
    createPart(pivot, "Pommel", "Sphere",
        Vector3(0.055, 0.055, 0.055),
        Vector3(0, -0.23, 0), guardMat)

    -- 护手中心辉光球 + 点光源
    local glowNode = createPart(pivot, "GlowOrb", "Sphere",
        Vector3(0.04, 0.04, 0.04),
        Vector3(0, 0.02, 0.03), glowMat)
    local pl = glowNode:CreateComponent("Light")
    pl.lightType = LIGHT_POINT
    pl.castShadows = false
    pl.range = 1.5
    pl.color = glowColor
    pl.brightness = 1.2

    return pivot
end

-- ============================================================================
-- Slash trail 特效
-- ============================================================================

local function spawnSlashTrail(worldPos, worldRot, color)
    if not scene_ then return end
    local node = scene_:CreateChild("SlashTrail")
    node.position = worldPos
    node.rotation = worldRot
    node:SetScale(Vector3(0.6, 0.015, 0.12))
    local mdl = node:CreateComponent("StaticModel")
    mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    mdl:SetMaterial(GameConfig.CreateAlphaMaterial(
        Color(color.r, color.g, color.b, 0.35), 0.5))
    table.insert(activeTrails_, { node = node, life = 0.15, maxLife = 0.15 })
end

local function updateTrails(dt)
    local i = 1
    while i <= #activeTrails_ do
        local tr = activeTrails_[i]
        tr.life = tr.life - dt
        if tr.life <= 0 then
            tr.node:Remove()
            table.remove(activeTrails_, i)
        else
            -- 淡出：缩小 + 透明
            local ratio = tr.life / tr.maxLife
            local s = tr.node.scale
            tr.node:SetScale(Vector3(s.x, s.y * ratio, s.z))
            i = i + 1
        end
    end
end

-- ============================================================================
-- 动画位姿计算
-- ============================================================================

local function getIdlePose(t)
    local bobY = math.sin(t * 2.0) * 0.008
    local bobX = math.sin(t * 1.3) * 0.004
    local rockZ = math.sin(t * 1.7) * 1.0
    local pos = Vector3(REST_POS.x + bobX, REST_POS.y + bobY, REST_POS.z)
    local rot = REST_ROT * Quaternion(0, 0, rockZ)
    return pos, rot
end

local function getSwing1Pose(t)
    if t < 0.30 then
        -- 蓄力阶段（ease-in 加速）
        local lt = easeInQuad(t / 0.30)
        return lerpVec3(REST_POS, WINDUP_POS, lt),
               REST_ROT:Slerp(WINDUP_ROT, lt)
    else
        -- 斩击阶段（ease-out 减速）
        local lt = easeOutQuad((t - 0.30) / 0.70)
        return lerpVec3(WINDUP_POS, SLASH1_POS, lt),
               WINDUP_ROT:Slerp(SLASH1_ROT, lt)
    end
end

local function getSwing2Pose(t)
    local lt = easeOutQuad(t)
    return lerpVec3(SLASH1_POS, SLASH2_POS, lt),
           SLASH1_ROT:Slerp(SLASH2_ROT, lt)
end

local function getDownwardPose(t)
    if t < 0.40 then
        -- 抬剑阶段
        local lt = easeInQuad(t / 0.40)
        return lerpVec3(REST_POS, RAISE_POS, lt),
               REST_ROT:Slerp(RAISE_ROT, lt)
    else
        -- 下劈阶段（快速 ease-out）
        local lt = easeOutQuad((t - 0.40) / 0.60)
        return lerpVec3(RAISE_POS, CHOP_POS, lt),
               RAISE_ROT:Slerp(CHOP_ROT, lt)
    end
end

local function getRecoveryPose(t, startPos, startRot)
    -- 弹性回归（带过冲）
    local lt = easeOutBack(math.min(t, 1.0))
    return lerpVec3(startPos, REST_POS, lt),
           startRot:Slerp(REST_ROT, lt)
end

-- ============================================================================
-- 状态转换
-- ============================================================================

local recoveryStartPos_ = REST_POS
local recoveryStartRot_ = REST_ROT

local function transitionTo(newState)
    -- 记录 recovery 起始位姿
    if newState == STATE_RECOVERY then
        recoveryStartPos_ = Vector3(currentPos_.x, currentPos_.y, currentPos_.z)
        recoveryStartRot_ = Quaternion(currentRot_.w, currentRot_.x, currentRot_.y, currentRot_.z)
    end
    animState_ = newState
    stateTimer_ = 0.0
    hitFired_ = false
end

local function onStateComplete()
    if animState_ == STATE_SWING1 then
        -- SWING_1 完成 → 进入 SWING_2
        transitionTo(STATE_SWING2)
    elseif animState_ == STATE_SWING2 then
        -- SWING_2 完成 → 检查连招
        if pendingCombo_ then
            pendingCombo_ = false
            transitionTo(STATE_DOWNWARD)
        else
            transitionTo(STATE_RECOVERY)
        end
    elseif animState_ == STATE_DOWNWARD then
        pendingCombo_ = false
        transitionTo(STATE_RECOVERY)
    elseif animState_ == STATE_RECOVERY then
        animState_ = STATE_IDLE
        stateTimer_ = 0.0
    end
end

-- ============================================================================
-- 公共接口
-- ============================================================================

--- 初始化
---@param sceneRef Scene
---@param camNode Node 相机节点
---@param hitFrameCallback function(weaponId, attackType)
function MeleeWeaponView.Init(sceneRef, camNode, hitFrameCallback)
    scene_ = sceneRef
    cameraNode_ = camNode
    onHitFrame_ = hitFrameCallback
    weaponId_ = nil

    -- 清理旧模型
    if weaponPivot_ then
        weaponPivot_:Remove()
        weaponPivot_ = nil
    end

    -- 默认辉光色
    local defaultGlow = Color(0.4, 0.8, 1.0, 1.0)
    weaponPivot_ = buildSwordModel(cameraNode_, defaultGlow)

    -- 初始位姿
    currentPos_ = Vector3(REST_POS.x, REST_POS.y, REST_POS.z)
    currentRot_ = Quaternion(REST_ROT.w, REST_ROT.x, REST_ROT.y, REST_ROT.z)
    animState_ = STATE_IDLE
    stateTimer_ = 0.0
    time_ = 0.0
    hitFired_ = false
    pendingCombo_ = false
    shakeTimer_ = 0.0
    activeTrails_ = {}

    print("[MeleeWeaponView] 近战武器视图已初始化")
end

--- 重置
function MeleeWeaponView.Reset()
    animState_ = STATE_IDLE
    stateTimer_ = 0.0
    hitFired_ = false
    pendingCombo_ = false
    shakeTimer_ = 0.0
    -- 清理特效
    for _, tr in ipairs(activeTrails_) do
        tr.node:Remove()
    end
    activeTrails_ = {}
end

--- 设置武器 ID（影响辉光颜色等）
---@param wid string|nil
function MeleeWeaponView.SetWeapon(wid)
    weaponId_ = wid
    if not weaponPivot_ then return end
    -- 更新辉光颜色
    local cfg = wid and GameConfig.Weapons[wid]
    local glowColor = (cfg and cfg.glowColor) or Color(0.4, 0.8, 1.0, 1.0)
    local glowOrb = weaponPivot_:GetChild("GlowOrb", false)
    if glowOrb then
        local mdl = glowOrb:GetComponent("StaticModel")
        if mdl then
            mdl:SetMaterial(GameConfig.CreateEmissiveMaterial(glowColor, 3.0))
        end
        local pl = glowOrb:GetComponent("Light")
        if pl then
            pl.color = glowColor
        end
    end
end

--- 设置可见性
---@param visible boolean
function MeleeWeaponView.SetVisible(visible)
    if weaponPivot_ then
        weaponPivot_:SetEnabled(visible)
    end
end

--- 触发攻击动画
---@param wid string 武器 ID
function MeleeWeaponView.TriggerAttack(wid)
    weaponId_ = wid
    if animState_ == STATE_IDLE or animState_ == STATE_RECOVERY then
        -- 新攻击
        pendingCombo_ = false
        transitionTo(STATE_SWING1)
    elseif animState_ == STATE_SWING1 or animState_ == STATE_SWING2 then
        -- 队列连招
        pendingCombo_ = true
    end
end

--- 是否正在播放攻击动画
---@return boolean
function MeleeWeaponView.IsAnimating()
    return animState_ ~= STATE_IDLE
end

--- 触发屏幕震动（命中反馈）
function MeleeWeaponView.TriggerShake()
    shakeTimer_ = 0.08
    shakeIntensity_ = 0.025
end

--- 每帧更新
---@param dt number
function MeleeWeaponView.Update(dt)
    if not weaponPivot_ then return end

    time_ = time_ + dt

    -- 更新 slash trails
    updateTrails(dt)

    local targetPos, targetRot

    if animState_ == STATE_IDLE then
        -- idle 呼吸微摇
        targetPos, targetRot = getIdlePose(time_)
    else
        -- 攻击动画
        stateTimer_ = stateTimer_ + dt
        local duration = DURATIONS[animState_]
        if not duration then
            animState_ = STATE_IDLE
            return
        end
        local t = math.min(stateTimer_ / duration, 1.0)

        if animState_ == STATE_SWING1 then
            targetPos, targetRot = getSwing1Pose(t)

            -- 连招输入检测
            if t >= COMBO_WINDOW_T and input:GetMouseButtonPress(MOUSEB_LEFT) then
                pendingCombo_ = true
            end

            -- Slash trail（斩击阶段）
            if t > 0.35 and t < 0.85 and math.fmod(t, 0.12) < dt / duration then
                local wp = weaponPivot_.worldPosition
                local wr = weaponPivot_.worldRotation
                local cfg = weaponId_ and GameConfig.Weapons[weaponId_]
                local col = (cfg and cfg.glowColor) or Color(0.4, 0.8, 1.0, 1.0)
                spawnSlashTrail(wp + wr * Vector3(0, 0.4, 0.1), wr, col)
            end

        elseif animState_ == STATE_SWING2 then
            targetPos, targetRot = getSwing2Pose(t)

        elseif animState_ == STATE_DOWNWARD then
            targetPos, targetRot = getDownwardPose(t)

            -- Slash trail（下劈阶段）
            if t > 0.45 and t < 0.90 and math.fmod(t, 0.10) < dt / duration then
                local wp = weaponPivot_.worldPosition
                local wr = weaponPivot_.worldRotation
                local cfg = weaponId_ and GameConfig.Weapons[weaponId_]
                local col = (cfg and cfg.glowColor) or Color(0.4, 0.8, 1.0, 1.0)
                spawnSlashTrail(wp + wr * Vector3(0, 0.2, 0.15), wr * Quaternion(90, 0, 0), col)
            end

        elseif animState_ == STATE_RECOVERY then
            targetPos, targetRot = getRecoveryPose(t, recoveryStartPos_, recoveryStartRot_)
        end

        -- Hit frame 检测
        if not hitFired_ and HIT_FRAME_T[animState_] and t >= HIT_FRAME_T[animState_] then
            hitFired_ = true
            if onHitFrame_ then
                onHitFrame_(weaponId_, animState_)
            end
        end

        -- 状态完成
        if t >= 1.0 then
            onStateComplete()
        end
    end

    -- 平滑跟随（防止突变）
    local smoothSpeed = (animState_ == STATE_IDLE) and 8.0 or 18.0
    local s = math.min(1.0, smoothSpeed * dt)
    currentPos_ = lerpVec3(currentPos_, targetPos, s)
    currentRot_ = currentRot_:Slerp(targetRot, s)

    -- 应用屏幕震动偏移
    local finalPos = currentPos_
    if shakeTimer_ > 0 then
        shakeTimer_ = shakeTimer_ - dt
        local shake = shakeIntensity_ * (shakeTimer_ / 0.08)
        finalPos = Vector3(
            currentPos_.x + (math.random() - 0.5) * shake * 2,
            currentPos_.y + (math.random() - 0.5) * shake * 2,
            currentPos_.z
        )
    end

    weaponPivot_.position = finalPos
    weaponPivot_.rotation = currentRot_
end

return MeleeWeaponView
