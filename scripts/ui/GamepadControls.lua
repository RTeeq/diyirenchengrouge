-- ============================================================================
-- GamepadControls.lua — 手柄输入管理模块
-- 读取物理手柄（Xbox/PS/通用控制器）输入，提供统一的查询接口
-- 与 MobileControls 并列，通过外部注入模式驱动 FirstPersonController
-- ============================================================================

local GameConfig = require("config.GameConfig")

local GamepadControls = {}

-- ============================================================================
-- 按钮映射（标准 Xbox 布局）
-- ============================================================================

local BTN = {
    A     = 0,   -- 跳跃
    B     = 1,   -- 交互
    X     = 2,   -- 左键攻击
    Y     = 3,   -- 右键攻击
    LB    = 4,   -- 上一武器
    RB    = 5,   -- 下一武器
    BACK  = 6,   -- Back
    START = 7,   -- 菜单/ESC
    L3    = 8,   -- 冲刺切换
    R3    = 9,   -- 右摇杆按下
}

local AXIS = {
    LEFT_X  = 0,  -- 左摇杆水平
    LEFT_Y  = 1,  -- 左摇杆垂直
    RIGHT_X = 2,  -- 右摇杆水平
    RIGHT_Y = 3,  -- 右摇杆垂直
    LT      = 4,  -- 左扳机
    RT      = 5,  -- 右扳机
}

-- 按钮名称 → 按钮索引映射
local NAME_TO_BTN = {
    jump        = BTN.A,
    interact    = BTN.B,
    attackLeft  = BTN.X,
    attackRight = BTN.Y,
    prevWeapon  = BTN.LB,
    nextWeapon  = BTN.RB,
    sprint      = BTN.L3,
    menu        = BTN.START,
}

-- ============================================================================
-- 内部状态
-- ============================================================================

---@type JoystickState|nil
local joystick_ = nil           -- 当前手柄引用
local connected_ = false        -- 手柄是否连接
local sprintToggle_ = false     -- 冲刺 toggle 状态
local hadInputThisFrame_ = false -- 本帧是否有手柄输入（用于自动模式检测）

-- ============================================================================
-- 死区处理
-- ============================================================================

---@param value number 摇杆原始值 -1~1
---@return number 处理后的值
local function applyDeadzone(value)
    local dz = GameConfig.Gamepad.Deadzone
    if math.abs(value) < dz then
        return 0
    end
    -- 将死区外的范围重新映射到 0~1
    local sign = value > 0 and 1 or -1
    return sign * (math.abs(value) - dz) / (1.0 - dz)
end

-- ============================================================================
-- 每帧更新
-- ============================================================================

--- 每帧调用，检测手柄连接并缓存状态
---@param dt number
function GamepadControls.Update(dt)
    -- 检测手柄
    local numJoysticks = input:GetNumJoysticks()
    joystick_ = nil
    connected_ = false

    for i = 0, numJoysticks - 1 do
        local js = input:GetJoystickByIndex(i)
        if js and js:IsController() then
            joystick_ = js
            connected_ = true
            break
        end
    end

    -- 如果没有找到 controller 类型，尝试使用第一个可用的手柄
    if not connected_ and numJoysticks > 0 then
        local js = input:GetJoystickByIndex(0)
        if js then
            joystick_ = js
            connected_ = true
        end
    end

    -- 检测是否有输入活动
    hadInputThisFrame_ = false
    if connected_ and joystick_ then
        -- 检查摇杆活动
        for axis = 0, 3 do
            if math.abs(joystick_:GetAxisPosition(axis)) > GameConfig.Gamepad.Deadzone then
                hadInputThisFrame_ = true
                break
            end
        end
        -- 检查按钮活动
        if not hadInputThisFrame_ then
            for _, btnIdx in pairs(BTN) do
                if joystick_:GetButtonDown(btnIdx) then
                    hadInputThisFrame_ = true
                    break
                end
            end
        end
    end

    -- L3 冲刺 toggle
    if GamepadControls.WasButtonPressed(BTN.L3) then
        sprintToggle_ = not sprintToggle_
    end
end

-- ============================================================================
-- 底层按钮查询
-- ============================================================================

--- 查询手柄按钮是否在本帧按下（单次触发）
---@param btnIndex number 按钮索引
---@return boolean
function GamepadControls.WasButtonPressed(btnIndex)
    if not connected_ or not joystick_ then return false end
    return joystick_:GetButtonPress(btnIndex)
end

--- 查询手柄按钮是否持续按住
---@param btnIndex number 按钮索引
---@return boolean
function GamepadControls.IsButtonDown(btnIndex)
    if not connected_ or not joystick_ then return false end
    return joystick_:GetButtonDown(btnIndex)
end

-- ============================================================================
-- 高层查询接口（与 MobileControls 对齐）
-- ============================================================================

--- 手柄是否连接
---@return boolean
function GamepadControls.IsConnected()
    return connected_
end

--- 查询命名按钮本帧是否按下（单次触发）
---@param name string 按钮名称：jump/interact/attackLeft/attackRight/prevWeapon/nextWeapon/sprint/menu
---@return boolean
function GamepadControls.WasPressed(name)
    local btnIdx = NAME_TO_BTN[name]
    if not btnIdx then return false end
    return GamepadControls.WasButtonPressed(btnIdx)
end

--- 查询命名按钮是否持续按住
---@param name string
---@return boolean
function GamepadControls.IsHeld(name)
    if name == "sprint" then
        return sprintToggle_
    end
    local btnIdx = NAME_TO_BTN[name]
    if not btnIdx then return false end
    return GamepadControls.IsButtonDown(btnIdx)
end

--- 获取左摇杆移动输入（含死区处理）
---@return number x, number z 水平方向分量（x=左右，z=前后）
function GamepadControls.GetMoveInput()
    if not connected_ or not joystick_ then return 0, 0 end
    local x = applyDeadzone(joystick_:GetAxisPosition(AXIS.LEFT_X))
    local y = applyDeadzone(joystick_:GetAxisPosition(AXIS.LEFT_Y))
    -- y 轴：手柄向上推为负值，需要反转为正值（代表前进）
    return x, -y
end

--- 获取右摇杆视角增量（含死区处理和灵敏度）
---@param dt number
---@return number deltaYaw, number deltaPitch
function GamepadControls.GetLookDelta(dt)
    if not connected_ or not joystick_ then return 0, 0 end
    local rx = applyDeadzone(joystick_:GetAxisPosition(AXIS.RIGHT_X))
    local ry = applyDeadzone(joystick_:GetAxisPosition(AXIS.RIGHT_Y))
    local sens = GameConfig.Gamepad.Sensitivity
    -- 右摇杆水平 → yaw（左右转），垂直 → pitch（上下看）
    -- 乘以 dt 和灵敏度，让视角旋转速度一致
    local deltaYaw = rx * sens * 120 * dt
    local deltaPitch = ry * sens * 120 * dt
    return deltaYaw, deltaPitch
end

--- 本帧是否有手柄输入活动（用于自动模式检测）
---@return boolean
function GamepadControls.IsActive()
    return hadInputThisFrame_
end

--- 重置冲刺 toggle 状态
function GamepadControls.ResetSprint()
    sprintToggle_ = false
end

return GamepadControls
