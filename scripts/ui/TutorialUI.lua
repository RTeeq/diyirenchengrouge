-- ============================================================================
-- TutorialUI.lua — 新手引导教程系统
-- 分步骤引导玩家掌握核心操作，完成后存档不再重复显示
-- ============================================================================

local GameConfig = require("config.GameConfig")
local UI = require("urhox-libs/UI")

local TutorialUI = {}

-- 存档文件
local SAVE_FILE = "tutorial_done.flag"

-- UI 引用
local root_ = nil
local stepLabel_ = nil
local hintLabel_ = nil
local skipLabel_ = nil
local progressDots_ = {}

-- 状态
local active_ = false
local currentStep_ = 1
local stepTimer_ = 0         -- 当前步骤已持续时间
local fadeAlpha_ = 0         -- 淡入动画 0→1
local completeFade_ = 0      -- 完成淡出动画
local completing_ = false    -- 正在播放完成动画
local onComplete_ = nil      -- 完成回调

-- 检测缓存
local movedDistance_ = 0     -- 移动累计
local lookDelta_ = 0         -- 视角累计
local lastMouseX_ = -1
local lastMouseY_ = -1

-- 前向声明
local updateStepUI

-- ============================================================================
-- 教程步骤定义（不含开发者模式和无人机模式）
-- ============================================================================

---@class TutorialStep
---@field title string 步骤标题
---@field hint string 操作提示
---@field check fun(dt:number):boolean 完成条件检测

local steps_ = {
    -- 1. 移动
    {
        title = "移  动",
        hint = "按  W A S D  移动角色",
        check = function(dt)
            local w = input:GetKeyDown(KEY_W)
            local a = input:GetKeyDown(KEY_A)
            local s = input:GetKeyDown(KEY_S)
            local d = input:GetKeyDown(KEY_D)
            if w or a or s or d then
                movedDistance_ = movedDistance_ + dt
            end
            return movedDistance_ > 1.0  -- 持续移动 1 秒
        end,
    },
    -- 2. 视角
    {
        title = "视  角",
        hint = "移动鼠标  环顾四周",
        check = function(dt)
            local mx = input.mousePosition.x
            local my = input.mousePosition.y
            if lastMouseX_ >= 0 then
                local dx = math.abs(mx - lastMouseX_)
                local dy = math.abs(my - lastMouseY_)
                lookDelta_ = lookDelta_ + dx + dy
            end
            lastMouseX_ = mx
            lastMouseY_ = my
            return lookDelta_ > 200  -- 累积移动 200 像素
        end,
    },
    -- 3. 跳跃
    {
        title = "跳  跃",
        hint = "按  空格键  跳跃",
        check = function(dt)
            return input:GetKeyPress(KEY_SPACE)
        end,
    },
    -- 4. 冲刺
    {
        title = "冲  刺",
        hint = "按住  Shift  加速冲刺",
        check = function(dt)
            if input:GetKeyDown(KEY_SHIFT) then
                movedDistance_ = movedDistance_ + dt
            else
                movedDistance_ = 0
            end
            return movedDistance_ > 0.8  -- 持续冲刺 0.8 秒
        end,
        onEnter = function()
            movedDistance_ = 0  -- 重用计数器
        end,
    },
    -- 5. 攻击
    {
        title = "攻  击",
        hint = "左键  使用道具  /  右键  挥剑攻击",
        check = function(dt)
            return input:GetMouseButtonPress(MOUSEB_LEFT)
                or input:GetMouseButtonPress(MOUSEB_RIGHT)
        end,
    },
    -- 6. 闪现
    {
        title = "闪  现",
        hint = "快速双击 Shift 闪现位移（附带短暂无敌）",
        check = function(dt)
            local FPC = require("core.FirstPersonController")
            if FPC.DashJustFired and FPC.DashJustFired() then
                return true
            end
            return false
        end,
    },
    -- 7. 组合技
    {
        title = "组合技",
        hint = "体力满时  按住 Shift+右键 蓄力  释放必杀一击",
        check = function(dt)
            local FPC = require("core.FirstPersonController")
            local state = FPC.GetComboState and FPC.GetComboState() or "idle"
            -- 进入 rushing 或 active 阶段即视为完成
            return state == "rushing" or state == "active"
        end,
    },
    -- 8. 交互说明（纯展示，按任意键继续）
    {
        title = "交  互",
        hint = "靠近 NPC 或物品  按 F 交互",
        check = function(dt)
            stepTimer_ = stepTimer_ + dt
            return stepTimer_ > 3.0
                or input:GetKeyPress(KEY_F)
                or input:GetMouseButtonPress(MOUSEB_LEFT)
        end,
        onEnter = function() stepTimer_ = 0 end,
    },
    -- 9. 快捷键总览（纯展示）
    {
        title = "快捷键",
        hint = "Tab 图鉴 │ M 地图 │ Q/E 切换武器 │ 滚轮 切换道具 │ ESC 暂停",
        check = function(dt)
            stepTimer_ = stepTimer_ + dt
            return stepTimer_ > 4.0
                or input:GetKeyPress(KEY_TAB)
                or input:GetKeyPress(KEY_M)
                or input:GetKeyPress(KEY_ESCAPE)
                or input:GetMouseButtonPress(MOUSEB_LEFT)
        end,
        onEnter = function() stepTimer_ = 0 end,
    },
}

-- ============================================================================
-- 存档检查
-- ============================================================================

--- 检查教程是否已完成
---@return boolean
function TutorialUI.IsCompleted()
    return fileSystem:FileExists(SAVE_FILE)
end

--- 标记教程已完成
local function markCompleted()
    local file = File(SAVE_FILE, FILE_WRITE)
    if file:IsOpen() then
        file:WriteString("1")
        file:Close()
    end
end

--- 重置教程完成状态（下次新建存档时重新触发教程）
function TutorialUI.ResetCompleted()
    if fileSystem:FileExists(SAVE_FILE) then
        fileSystem:Delete(SAVE_FILE)
    end
    print("[TutorialUI] 教程完成状态已重置")
end

-- ============================================================================
-- 初始化 UI
-- ============================================================================

---@return table UI 面板（需插入到 UI 树中）
function TutorialUI.Init()
    -- 步骤进度指示器（圆点）
    local dotChildren = {}
    for i = 1, #steps_ do
        local dot = UI.Panel {
            id = "tutDot" .. i,
            width = 8,
            height = 8,
            borderRadius = 4,
            backgroundColor = { 255, 255, 255, 40 },
            marginLeft = (i > 1) and 6 or 0,
        }
        table.insert(dotChildren, dot)
        table.insert(progressDots_, dot)
    end

    local dotsRow = UI.Panel {
        flexDirection = "row",
        justifyContent = "center",
        alignItems = "center",
        marginBottom = 10,
        children = dotChildren,
    }

    -- 步骤标题
    stepLabel_ = UI.Label {
        id = "tutStepTitle",
        text = "",
        fontSize = 14,
        fontColor = { 180, 200, 255, 200 },
        marginBottom = 6,
        textAlign = "center",
    }

    -- 操作提示（大字）
    hintLabel_ = UI.Label {
        id = "tutHintText",
        text = "",
        fontSize = 20,
        fontWeight = "bold",
        fontColor = { 255, 255, 255, 240 },
        marginBottom = 10,
        textAlign = "center",
    }

    -- 跳过提示
    skipLabel_ = UI.Label {
        id = "tutSkipHint",
        text = "按 ESC 跳过教程",
        fontSize = 11,
        fontColor = { 255, 255, 255, 80 },
        textAlign = "center",
    }

    -- 主面板（底部居中）
    root_ = UI.Panel {
        id = "tutorialRoot",
        position = "absolute",
        bottom = 80,
        left = "50%",
        marginLeft = -270,
        width = 540,
        paddingTop = 16,
        paddingBottom = 14,
        paddingLeft = 28,
        paddingRight = 28,
        backgroundColor = { 10, 12, 20, 180 },
        borderRadius = 12,
        borderWidth = 1,
        borderColor = { 100, 140, 255, 60 },
        alignItems = "center",
        visible = false,
        pointerEvents = "none",
        children = {
            dotsRow,
            stepLabel_,
            hintLabel_,
            skipLabel_,
        },
    }

    print("[TutorialUI] 初始化完成, " .. #steps_ .. " 个步骤")
    return root_
end

-- ============================================================================
-- 开始 / 跳过 / 完成
-- ============================================================================

--- 开始教程
---@param onDone function? 完成回调
function TutorialUI.Start(onDone)
    if not root_ then return end
    onComplete_ = onDone
    active_ = true
    currentStep_ = 1
    fadeAlpha_ = 0
    completeFade_ = 0
    completing_ = false
    movedDistance_ = 0
    lookDelta_ = 0
    lastMouseX_ = -1
    lastMouseY_ = -1
    stepTimer_ = 0

    root_:Show()
    updateStepUI()
    print("[TutorialUI] 教程开始")
end

--- 跳过教程
function TutorialUI.Skip()
    if not active_ then return end
    active_ = false
    markCompleted()
    if root_ then root_:Hide() end
    if onComplete_ then onComplete_() end
    print("[TutorialUI] 教程已跳过")
end

--- 完成教程（播放淡出后回调）
local function finishTutorial()
    completing_ = true
    completeFade_ = 1.0
end

-- ============================================================================
-- 更新步骤 UI
-- ============================================================================

updateStepUI = function()
    if not root_ then return end
    local step = steps_[currentStep_]
    if not step then return end

    -- 更新文字
    stepLabel_:SetText("第 " .. currentStep_ .. "/" .. #steps_ .. " 步 — " .. step.title)
    hintLabel_:SetText(step.hint)

    -- 更新进度圆点
    for i, dot in ipairs(progressDots_) do
        if i < currentStep_ then
            -- 已完成：亮蓝色
            dot:SetStyle({ backgroundColor = { 100, 180, 255, 200 } })
        elseif i == currentStep_ then
            -- 当前：白色
            dot:SetStyle({ backgroundColor = { 255, 255, 255, 240 } })
        else
            -- 未到：暗灰
            dot:SetStyle({ backgroundColor = { 255, 255, 255, 40 } })
        end
    end

    -- 重置淡入
    fadeAlpha_ = 0

    -- 调用步骤的 onEnter
    if step.onEnter then step.onEnter() end
end

-- ============================================================================
-- 帧更新
-- ============================================================================

---@param dt number
function TutorialUI.Update(dt)
    if not active_ then return end

    -- ESC 跳过
    if input:GetKeyPress(KEY_ESCAPE) then
        TutorialUI.Skip()
        return
    end

    -- 完成淡出
    if completing_ then
        completeFade_ = completeFade_ - dt * 2.0  -- 0.5 秒淡出
        if completeFade_ <= 0 then
            completeFade_ = 0
            active_ = false
            markCompleted()
            if root_ then root_:Hide() end
            if onComplete_ then onComplete_() end
            print("[TutorialUI] 教程完成！")
        end
        -- 更新面板透明度
        local a = math.floor(completeFade_ * 180)
        if root_ then
            root_:SetStyle({ backgroundColor = { 10, 12, 20, a } })
        end
        return
    end

    -- 淡入
    if fadeAlpha_ < 1 then
        fadeAlpha_ = math.min(1, fadeAlpha_ + dt * 3.0)  -- 0.33 秒淡入
    end

    -- 检测当前步骤完成条件
    local step = steps_[currentStep_]
    if step and step.check(dt) then
        -- 当前步骤完成
        if currentStep_ < #steps_ then
            -- 进入下一步
            currentStep_ = currentStep_ + 1
            movedDistance_ = 0
            lookDelta_ = 0
            lastMouseX_ = -1
            lastMouseY_ = -1
            stepTimer_ = 0
            updateStepUI()
        else
            -- 全部完成
            finishTutorial()
        end
    end

    -- 更新提示文字脉冲动画
    if hintLabel_ and not completing_ then
        local pulse = 0.85 + 0.15 * math.sin(time.elapsedTime * 3.0)
        local a = math.floor(240 * pulse * fadeAlpha_)
        hintLabel_:SetStyle({ fontColor = { 255, 255, 255, a } })
    end

    -- 跳过提示闪烁
    if skipLabel_ then
        local sa = math.floor(60 + 30 * math.sin(time.elapsedTime * 2.0))
        skipLabel_:SetStyle({ fontColor = { 255, 255, 255, sa } })
    end
end

-- ============================================================================
-- 查询
-- ============================================================================

function TutorialUI.IsActive()
    return active_
end

function TutorialUI.GetStep()
    return currentStep_
end

return TutorialUI
