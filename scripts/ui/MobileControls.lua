-- ============================================================================
-- MobileControls.lua — 手游虚拟操控管理模块
-- 封装 VirtualControls 库，提供统一的虚拟控件创建和状态查询接口
-- 支持 Auto / PC / Mobile 三种操控模式
-- ============================================================================

local VirtualControls = require("urhox-libs.UI.VirtualControls")
local PlatformUtils = require("urhox-libs.Platform.PlatformUtils")
local GameConfig = require("config.GameConfig")

local MobileControls = {}

-- ============================================================================
-- 内部状态
-- ============================================================================

local initialized_ = false
local mobileMode_ = false        -- 当前是否处于手游模式
local modeSetting_ = "auto"      -- "auto" / "pc" / "mobile"
local visible_ = true            -- 是否可见（非 PLAYING 状态时隐藏）

-- 按钮实例引用
local joystick_ = nil            -- 移动摇杆
local touchLookArea_ = nil       -- 触控视角区域
local btnAttack_ = nil           -- 左键攻击
local btnAttackRight_ = nil      -- 右键攻击
local btnJump_ = nil             -- 跳跃
local btnInteract_ = nil         -- 交互
local btnSprint_ = nil           -- 冲刺（toggle）
local btnPrevWeapon_ = nil       -- 切换武器 Q
local btnNextWeapon_ = nil       -- 切换武器 E
local btnSkills_ = {}            -- 技能按钮 1-4

-- 单帧按下状态（每帧清空）
local pressedThisFrame_ = {}

-- 外部注入的视角增量（来自 TouchLookArea）
local lookDeltaYaw_ = 0
local lookDeltaPitch_ = 0

-- 外部注入的攻击回调（来自 TouchLookArea 的 tap）
local onTouchTap_ = nil

-- ============================================================================
-- 初始化
-- ============================================================================

function MobileControls.Init()
    if initialized_ then return end

    -- 自动判断平台
    mobileMode_ = MobileControls._resolveMobileMode()

    -- 初始化 VirtualControls（设计分辨率 1920x1080）
    VirtualControls.Initialize(1920, 1080)
    VirtualControls.SetMobileMode(mobileMode_)

    -- 创建所有虚拟控件
    MobileControls._createControls()

    initialized_ = true
    print("[MobileControls] 初始化完成, 模式=" .. modeSetting_ .. ", 手游=" .. tostring(mobileMode_))
end

-- ============================================================================
-- 创建虚拟控件
-- ============================================================================

function MobileControls._createControls()
    -- ========== 左侧：移动摇杆 ==========
    joystick_ = VirtualControls.CreateJoystick({
        position = Vector2(-150, -150),
        alignment = { HA_LEFT, VA_BOTTOM },
        baseRadius = 100,
        knobRadius = 40,
        moveRadius = 60,
        keyBinding = "WASD",
        opacity = 0.4,
        activeOpacity = 0.8,
    })

    -- ========== 冲刺按钮（摇杆右上方，toggle 模式） ==========
    btnSprint_ = VirtualControls.CreateButton({
        position = Vector2(-30, -260),
        alignment = { HA_LEFT, VA_BOTTOM },
        radius = 28,
        label = "🏃",
        keyBinding = "SHIFT",
        toggle = true,
        opacity = 0.35,
        activeOpacity = 0.8,
        color = { 255, 200, 80 },
        pressedColor = { 255, 240, 120 },
        on_toggle = function(isToggled)
            -- sprint 状态由 IsHeld("sprint") 查询
        end,
    })

    -- ========== 右侧触控视角区域 ==========
    touchLookArea_ = VirtualControls.CreateTouchLookArea({
        regionPreset = "right_half",
        sensitivity = 0.15,
        on_look = function(deltaYaw, deltaPitch)
            lookDeltaYaw_ = lookDeltaYaw_ + deltaYaw
            lookDeltaPitch_ = lookDeltaPitch_ + deltaPitch
        end,
        on_tap = function()
            -- 右半屏点击 = 左键攻击
            pressedThisFrame_["attackLeft"] = true
            if onTouchTap_ then onTouchTap_() end
        end,
    })

    -- ========== 右侧按钮群 ==========

    -- 攻击按钮（右下角，大按钮）
    btnAttack_ = VirtualControls.CreateButton({
        position = Vector2(-90, -100),
        alignment = { HA_RIGHT, VA_BOTTOM },
        radius = 48,
        label = "⚔",
        mouseBinding = "LMB",
        opacity = 0.4,
        activeOpacity = 0.85,
        color = { 255, 100, 80 },
        pressedColor = { 255, 160, 120 },
        on_press = function()
            pressedThisFrame_["attackLeft"] = true
        end,
    })

    -- 副攻击按钮（攻击按钮左上方）
    btnAttackRight_ = VirtualControls.CreateButton({
        position = Vector2(-190, -160),
        alignment = { HA_RIGHT, VA_BOTTOM },
        radius = 38,
        label = "🗡",
        mouseBinding = "RMB",
        opacity = 0.35,
        activeOpacity = 0.8,
        color = { 200, 160, 255 },
        pressedColor = { 230, 200, 255 },
        on_press = function()
            pressedThisFrame_["attackRight"] = true
        end,
    })

    -- 跳跃按钮（攻击按钮上方）
    btnJump_ = VirtualControls.CreateButton({
        position = Vector2(-90, -210),
        alignment = { HA_RIGHT, VA_BOTTOM },
        radius = 34,
        label = "⬆",
        keyBinding = "SPACE",
        opacity = 0.35,
        activeOpacity = 0.8,
        color = { 120, 200, 255 },
        pressedColor = { 160, 230, 255 },
        on_press = function()
            pressedThisFrame_["jump"] = true
        end,
    })

    -- 交互按钮（右侧中部）
    btnInteract_ = VirtualControls.CreateButton({
        position = Vector2(-200, -260),
        alignment = { HA_RIGHT, VA_BOTTOM },
        radius = 32,
        label = "F",
        keyBinding = "F",
        opacity = 0.35,
        activeOpacity = 0.8,
        color = { 240, 220, 140 },
        pressedColor = { 255, 240, 180 },
        on_press = function()
            pressedThisFrame_["interact"] = true
        end,
    })

    -- ========== 武器切换按钮 ==========

    -- Q：上一个武器（底部偏左）
    btnPrevWeapon_ = VirtualControls.CreateButton({
        position = Vector2(-380, -30),
        alignment = { HA_CENTER, VA_BOTTOM },
        radius = 24,
        label = "◀",
        keyBinding = "Q",
        opacity = 0.3,
        activeOpacity = 0.7,
        color = { 180, 180, 200 },
        on_press = function()
            pressedThisFrame_["prevWeapon"] = true
        end,
    })

    -- E：下一个武器（底部偏右）
    btnNextWeapon_ = VirtualControls.CreateButton({
        position = Vector2(380, -30),
        alignment = { HA_CENTER, VA_BOTTOM },
        radius = 24,
        label = "▶",
        keyBinding = "E",
        opacity = 0.3,
        activeOpacity = 0.7,
        color = { 180, 180, 200 },
        on_press = function()
            pressedThisFrame_["nextWeapon"] = true
        end,
    })

    -- ========== 技能按钮 1-4（右侧上方竖排） ==========
    local skillLabels = { "1", "2", "3", "4" }
    local skillColors = {
        { 255, 120, 80 },   -- 火
        { 80, 180, 255 },   -- 冰
        { 180, 255, 120 },  -- 风
        { 255, 200, 80 },   -- 电
    }
    btnSkills_ = {}
    for i = 1, 4 do
        local keyStr = tostring(i)
        btnSkills_[i] = VirtualControls.CreateButton({
            position = Vector2(-30 - (4 - i) * 62, -310),
            alignment = { HA_RIGHT, VA_BOTTOM },
            radius = 26,
            label = skillLabels[i],
            keyBinding = keyStr,
            opacity = 0.3,
            activeOpacity = 0.75,
            color = skillColors[i],
            on_press = function()
                pressedThisFrame_["skill" .. i] = true
            end,
        })
    end
end

-- ============================================================================
-- 每帧更新
-- ============================================================================

--- 每帧调用，清空单帧状态。在游戏系统查询之前调用
function MobileControls.Update(dt)
    if not initialized_ then return end

    -- 清空上一帧的 pressedThisFrame（新按下会在 VirtualControls 的 on_press 回调中重新设置）
    pressedThisFrame_ = {}

    -- VirtualControls 的 Update 是自动通过 BeginFrame 事件调用的，无需手动调用
end

-- ============================================================================
-- 状态查询
-- ============================================================================

--- 查询某按钮本帧是否被按下（单次触发，仅手游模式下生效）
---@param name string 按钮名称
---@return boolean
function MobileControls.WasPressed(name)
    if not mobileMode_ then return false end
    return pressedThisFrame_[name] == true
end

--- 查询某按钮是否被持续按住（仅手游模式下生效）
---@param name string 按钮名称
---@return boolean
function MobileControls.IsHeld(name)
    if not mobileMode_ then return false end

    if name == "sprint" then
        return btnSprint_ ~= nil and (btnSprint_.isToggled or btnSprint_.isPressed)
    elseif name == "jump" then
        return btnJump_ ~= nil and btnJump_.isPressed
    elseif name == "attackLeft" then
        return btnAttack_ ~= nil and btnAttack_.isPressed
    elseif name == "attackRight" then
        return btnAttackRight_ ~= nil and btnAttackRight_.isPressed
    end
    return false
end

--- 获取摇杆输入方向（仅手游模式下有效）
---@return number x, number z 水平方向分量
function MobileControls.GetJoystickInput()
    if not mobileMode_ or not joystick_ then return 0, 0 end
    -- getMovement 返回 (x, y)，y 已反转（向上推=正值）
    local x, z = joystick_:getMovement()
    return x, z
end

--- 获取并消费本帧的视角增量
---@return number deltaYaw, number deltaPitch
function MobileControls.ConsumeLookDelta()
    local dy, dp = lookDeltaYaw_, lookDeltaPitch_
    lookDeltaYaw_ = 0
    lookDeltaPitch_ = 0
    return dy, dp
end

--- 当前是否手游模式
---@return boolean
function MobileControls.IsMobileMode()
    return mobileMode_
end

--- 当前是否手柄模式
---@return boolean
function MobileControls.IsGamepadMode()
    return modeSetting_ == "gamepad"
end

--- 获取当前模式设置字符串
---@return string "auto"|"pc"|"mobile"|"gamepad"
function MobileControls.GetModeSetting()
    return modeSetting_
end

-- ============================================================================
-- 模式切换
-- ============================================================================

--- 设置操控模式
---@param mode string "auto"|"pc"|"mobile"|"gamepad"
function MobileControls.SetMode(mode)
    modeSetting_ = mode
    mobileMode_ = MobileControls._resolveMobileMode()
    -- 手柄模式下隐藏虚拟控件（用物理手柄操作）
    VirtualControls.SetMobileMode(mobileMode_ and mode ~= "gamepad")
    print("[MobileControls] 切换模式: " .. mode .. ", 手游=" .. tostring(mobileMode_))
end

--- 显示/隐藏所有虚拟控件（非 PLAYING 状态时隐藏）
---@param vis boolean
function MobileControls.SetVisible(vis)
    visible_ = vis
    if not initialized_ then return end
    -- VirtualControls 没有全局 SetVisible，通过模式切换间接控制
    if vis then
        VirtualControls.SetMobileMode(mobileMode_)
    else
        VirtualControls.SetMobileMode(false)
    end
end

--- 设置触控 tap 回调（可选，用于 TouchLookArea 的 tap 触发攻击）
---@param cb function|nil
function MobileControls.OnTouchTap(cb)
    onTouchTap_ = cb
end

-- ============================================================================
-- 内部工具
-- ============================================================================

--- 根据 modeSetting_ 解析实际是否手游模式
---@return boolean
function MobileControls._resolveMobileMode()
    if modeSetting_ == "pc" then
        return false
    elseif modeSetting_ == "mobile" then
        return true
    elseif modeSetting_ == "gamepad" then
        return false  -- 手柄模式不是手游模式（不显示虚拟控件）
    else
        -- auto: 根据平台判断
        return PlatformUtils.IsMobilePlatform() or input.touchEmulation
    end
end

return MobileControls
