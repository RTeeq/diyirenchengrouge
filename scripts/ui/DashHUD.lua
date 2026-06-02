-- ============================================================================
-- DashHUD.lua — 闪现体力圆环 + 闪现次数格子 + 屏幕线条特效
-- 使用 NanoVG 绘制，叠加在准星周围
-- ============================================================================

local GameConfig = require("config.GameConfig")
local FirstPersonController = require("core.FirstPersonController")
local GameManager = require("core.GameManager")

local DashHUD = {}

---@type userdata NanoVG context
local vg_ = nil
local fontId_ = -1

-- 线条特效缓存（闪现触发时随机生成，持续显示到消失）
local cachedLines_ = {}
-- 冲刺线条缓存（组合技冲刺用，更密、更长、更快）
local cachedRushLines_ = {}

-- ============================================================================
-- 初始化
-- ============================================================================

function DashHUD.Init()
    vg_ = nvgCreate(1)
    if not vg_ then
        print("[DashHUD] ERROR: nvgCreate failed")
        return
    end

    fontId_ = nvgCreateFont(vg_, "dashfont", "Fonts/MiSans-Regular.ttf")

    SubscribeToEvent(vg_, "NanoVGRender", "HandleDashHUDRender")
    print("[DashHUD] 初始化完成")
end

function DashHUD.Destroy()
    if vg_ then
        nvgDelete(vg_)
        vg_ = nil
    end
end

-- ============================================================================
-- 渲染
-- ============================================================================

---@param eventType string
---@param eventData table
function HandleDashHUDRender(eventType, eventData)
    if not vg_ then return end

    -- 仅在游戏中显示
    if GameManager.GetState() ~= GameConfig.States.PLAYING then return end

    local gfx = GetGraphics()
    local w = gfx:GetWidth()
    local h = gfx:GetHeight()
    local dpr = gfx:GetDPR()
    local logW = w / dpr
    local logH = h / dpr

    nvgBeginFrame(vg_, logW, logH, dpr)

    local cx = logW * 0.5
    local cy = logH * 0.5

    -- 绘制体力圆环（准星外围）
    DrawStaminaRing(cx, cy)

    -- 绘制闪现次数格子（圆环下方）
    DrawChargeSlots(cx, cy)

    -- 闪现特效
    local linesFx = FirstPersonController.GetDashLinesFx()
    if linesFx > 0 then
        -- 半透明灰色色调
        DrawGrayOverlay(logW, logH, linesFx)
        -- 屏幕边缘线条
        DrawSpeedLines(logW, logH, linesFx)
    end

    -- === 闪现无敌帧特效 ===
    local invPct = FirstPersonController.GetDashInvPct and FirstPersonController.GetDashInvPct() or 0
    if invPct > 0 then
        DrawDashInvincible(logW, logH, invPct)
    end

    -- === 组合技屏幕特效 ===
    local comboState = FirstPersonController.GetComboState()
    if comboState == "charging" then
        DrawComboChargeRing(cx, cy, FirstPersonController.GetComboChargePct())
    end
    if comboState == "rushing" then
        -- 冲刺动态模糊 + 速度线条
        local rushPct = FirstPersonController.GetComboRushPct()
        DrawComboMotionBlur(logW, logH, rushPct)
        DrawComboRushLines(logW, logH, rushPct)
    end
    if comboState == "rushing" or FirstPersonController.GetComboRushFlash() > 0 then
        DrawComboRushFlash(logW, logH, FirstPersonController.GetComboRushFlash())
    end
    if comboState == "active" then
        DrawComboActiveTint(logW, logH, FirstPersonController.GetComboActivePct())
    end

    nvgEndFrame(vg_)
end

-- ============================================================================
-- 体力圆环
-- ============================================================================

local RING_RADIUS = 28        -- 圆环半径
local RING_WIDTH = 3           -- 圆环线宽
local RING_GAP = 6             -- 圆环与准星的间距

function DrawStaminaRing(cx, cy)
    local pct = FirstPersonController.GetDashStaminaPct()
    local r = RING_RADIUS

    -- 背景环（暗色）
    nvgBeginPath(vg_)
    nvgArc(vg_, cx, cy, r, 0, math.pi * 2, NVG_CW)
    nvgStrokeColor(vg_, nvgRGBA(255, 255, 255, 30))
    nvgStrokeWidth(vg_, RING_WIDTH)
    nvgStroke(vg_)

    -- 体力弧（从顶部顺时针）
    if pct > 0 then
        local startAngle = -math.pi * 0.5                      -- 12点方向
        local endAngle = startAngle + math.pi * 2 * pct

        -- 颜色：满=青色, 低=橙色
        local cr, cg, cb
        if pct > 0.5 then
            cr, cg, cb = 0, 220, 255       -- 青色
        elseif pct > 0.25 then
            cr, cg, cb = 255, 180, 0       -- 橙色
        else
            cr, cg, cb = 255, 60, 60       -- 红色
        end

        -- 闪现刚触发时闪白
        local alpha = 200
        if FirstPersonController.DashJustFired() then
            cr, cg, cb = 255, 255, 255
            alpha = 255
        end

        nvgBeginPath(vg_)
        nvgArc(vg_, cx, cy, r, startAngle, endAngle, NVG_CW)
        nvgStrokeColor(vg_, nvgRGBA(cr, cg, cb, alpha))
        nvgStrokeWidth(vg_, RING_WIDTH)
        nvgLineCap(vg_, NVG_ROUND)
        nvgStroke(vg_)
    end
end

-- ============================================================================
-- 闪现次数格子
-- ============================================================================

local SLOT_SIZE = 8            -- 格子大小
local SLOT_GAP = 4             -- 格子间距
local SLOT_OFFSET_Y = 22       -- 格子距准星中心的Y偏移

function DrawChargeSlots(cx, cy)
    local charges = FirstPersonController.GetDashCharges()
    local maxCharges = FirstPersonController.GetDashMaxCharges()

    if maxCharges <= 0 then return end

    local totalW = maxCharges * SLOT_SIZE + (maxCharges - 1) * SLOT_GAP
    local startX = cx - totalW * 0.5
    local slotY = cy + RING_RADIUS + SLOT_OFFSET_Y

    for i = 1, maxCharges do
        local sx = startX + (i - 1) * (SLOT_SIZE + SLOT_GAP)
        local filled = (i <= charges)

        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, sx, slotY, SLOT_SIZE, SLOT_SIZE, 2)

        if filled then
            -- 有电：青色填充
            nvgFillColor(vg_, nvgRGBA(0, 220, 255, 220))
            nvgFill(vg_)
        else
            -- 空：暗色边框
            nvgStrokeColor(vg_, nvgRGBA(255, 255, 255, 50))
            nvgStrokeWidth(vg_, 1)
            nvgStroke(vg_)
        end
    end
end

-- ============================================================================
-- 半透明灰色色调（闪现时画面变暗）
-- ============================================================================

function DrawGrayOverlay(w, h, fxProgress)
    -- fxProgress: 1→0, 用 easeOut 让暗色快速出现、缓慢消退
    local a = math.floor(60 * fxProgress * fxProgress)
    if a <= 0 then return end

    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, w, h)
    nvgFillColor(vg_, nvgRGBA(15, 15, 20, a))
    nvgFill(vg_)
end

-- ============================================================================
-- 屏幕边缘线条特效（从四边向内辐射的速度线）
-- ============================================================================

local LINE_COUNT = 32          -- 线条数量

--- 生成随机线条（分布在屏幕四边边缘，指向中心）
local function generateLines()
    cachedLines_ = {}
    for i = 1, LINE_COUNT do
        -- 随机选择一条边: 1=上, 2=下, 3=左, 4=右
        local edge = math.random(1, 4)
        -- 沿边缘的随机位置 (0~1)
        local pos = math.random() * 1.0
        -- 线条长度（屏幕对角线比例）
        local len = 0.06 + math.random() * 0.12
        -- 线条离边缘的距离（贴近边缘）
        local margin = math.random() * 0.03
        local width = 1 + math.random() * 2.5
        local alpha = 100 + math.random(100)

        table.insert(cachedLines_, {
            edge = edge,
            pos = pos,
            len = len,
            margin = margin,
            width = width,
            alpha = alpha,
        })
    end
end

function DrawSpeedLines(w, h, fxProgress)
    -- fxProgress: 1→0 (1=刚触发, 0=消失)

    -- 刚触发时生成线条
    if FirstPersonController.DashJustFired() then
        generateLines()
    end

    if #cachedLines_ == 0 then return end

    local globalAlpha = fxProgress
    local cx = w * 0.5
    local cy = h * 0.5

    for _, line in ipairs(cachedLines_) do
        -- 计算线条起点（在屏幕边缘）
        local startX, startY

        if line.edge == 1 then
            -- 上边
            startX = line.pos * w
            startY = line.margin * h
        elseif line.edge == 2 then
            -- 下边
            startX = line.pos * w
            startY = h - line.margin * h
        elseif line.edge == 3 then
            -- 左边
            startX = line.margin * w
            startY = line.pos * h
        else
            -- 右边
            startX = w - line.margin * w
            startY = line.pos * h
        end

        -- 从起点指向中心的方向
        local dx = cx - startX
        local dy = cy - startY
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist < 1 then dist = 1 end
        local nx = dx / dist
        local ny = dy / dist

        -- 线条长度随时间向内延伸
        local expandT = 1 - fxProgress  -- 0→1
        local lineLen = line.len * dist * (0.6 + expandT * 0.4)

        local x1 = startX
        local y1 = startY
        local x2 = startX + nx * lineLen
        local y2 = startY + ny * lineLen

        local a = math.floor(line.alpha * globalAlpha)

        nvgBeginPath(vg_)
        nvgMoveTo(vg_, x1, y1)
        nvgLineTo(vg_, x2, y2)
        nvgStrokeColor(vg_, nvgRGBA(200, 230, 255, a))
        nvgStrokeWidth(vg_, line.width)
        nvgLineCap(vg_, NVG_ROUND)
        nvgStroke(vg_)
    end
end

-- ============================================================================
-- 组合技屏幕特效
-- ============================================================================

--- 按组合技类型获取主题色 (r, g, b 范围 0~255)
local function getComboColor()
    local ct = FirstPersonController.GetComboType and FirstPersonController.GetComboType() or "sword_path"
    if ct == "ice_sweep" then
        return 80, 160, 255    -- 冰蓝
    elseif ct == "fire_sweep" then
        return 255, 120, 30    -- 烈焰橙
    elseif ct == "wind_release" then
        return 100, 255, 140   -- 风绿
    end
    return 255, 210, 60        -- 剑道金（默认）
end

--- 蓄力弧（围绕准星，从0到满，颜色随组合技类型变化）
function DrawComboChargeRing(cx, cy, pct)
    if pct <= 0 then return end
    local r = RING_RADIUS + 10
    local cr, cg, cb = getComboColor()

    -- 背景环
    nvgBeginPath(vg_)
    nvgArc(vg_, cx, cy, r, 0, math.pi * 2, NVG_CW)
    nvgStrokeColor(vg_, nvgRGBA(cr, cg, cb, 30))
    nvgStrokeWidth(vg_, 4)
    nvgStroke(vg_)

    -- 蓄力弧
    local startAngle = -math.pi * 0.5
    local endAngle = startAngle + math.pi * 2 * pct

    -- 脉动亮度
    local pulse = 180 + math.floor(math.sin(pct * 20) * 50)
    nvgBeginPath(vg_)
    nvgArc(vg_, cx, cy, r, startAngle, endAngle, NVG_CW)
    nvgStrokeColor(vg_, nvgRGBA(cr, cg, cb, pulse))
    nvgStrokeWidth(vg_, 4)
    nvgLineCap(vg_, NVG_ROUND)
    nvgStroke(vg_)

    -- 满蓄力闪烁提示
    if pct >= 0.95 then
        local flash = math.floor(math.abs(math.sin(pct * 40)) * 80)
        nvgBeginPath(vg_)
        nvgArc(vg_, cx, cy, r + 3, 0, math.pi * 2, NVG_CW)
        nvgStrokeColor(vg_, nvgRGBA(cr, cg, cb, flash))
        nvgStrokeWidth(vg_, 2)
        nvgStroke(vg_)
    end
end

--- 冲击闪屏（颜色随组合技类型变化）
function DrawComboRushFlash(w, h, flash)
    if flash <= 0 then return end
    -- flash: 1→0，闪白强度
    local a = math.floor(200 * flash * flash)
    if a <= 0 then return end

    local cr, cg, cb = getComboColor()
    -- 混合白色使闪屏更亮
    local fr = math.min(255, math.floor(cr * 0.5 + 255 * 0.5))
    local fg = math.min(255, math.floor(cg * 0.5 + 255 * 0.5))
    local fb = math.min(255, math.floor(cb * 0.5 + 255 * 0.5))

    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, w, h)
    nvgFillColor(vg_, nvgRGBA(fr, fg, fb, a))
    nvgFill(vg_)
end

--- 激活边缘色调（持续期间，颜色随组合技类型变化）
function DrawComboActiveTint(w, h, activePct)
    if activePct <= 0 then return end
    -- activePct: 1→0 (剩余时间比例)

    local cr, cg, cb = getComboColor()
    -- 暗角用稍暗的主题色
    local vr = math.floor(cr * 0.15)
    local vg2 = math.floor(cg * 0.15)
    local vb = math.floor(cb * 0.15)

    -- 边缘渐变暗角（从边缘向中心）
    local vignetteA = math.floor(40 * activePct)

    -- 上边缘
    local grad = nvgLinearGradient(vg_, 0, 0, 0, h * 0.15,
        nvgRGBA(vr, vg2, vb, vignetteA),
        nvgRGBA(vr, vg2, vb, 0))
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, w, h * 0.15)
    nvgFillPaint(vg_, grad)
    nvgFill(vg_)

    -- 下边缘
    grad = nvgLinearGradient(vg_, 0, h, 0, h * 0.85,
        nvgRGBA(vr, vg2, vb, vignetteA),
        nvgRGBA(vr, vg2, vb, 0))
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, h * 0.85, w, h * 0.15)
    nvgFillPaint(vg_, grad)
    nvgFill(vg_)

    -- 左边缘
    grad = nvgLinearGradient(vg_, 0, 0, w * 0.1, 0,
        nvgRGBA(vr, vg2, vb, vignetteA),
        nvgRGBA(vr, vg2, vb, 0))
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, w * 0.1, h)
    nvgFillPaint(vg_, grad)
    nvgFill(vg_)

    -- 右边缘
    grad = nvgLinearGradient(vg_, w, 0, w * 0.9, 0,
        nvgRGBA(vr, vg2, vb, vignetteA),
        nvgRGBA(vr, vg2, vb, 0))
    nvgBeginPath(vg_)
    nvgRect(vg_, w * 0.9, 0, w * 0.1, h)
    nvgFillPaint(vg_, grad)
    nvgFill(vg_)

    -- 脉动细线边框
    local pulse = math.sin(activePct * 30) * 0.5 + 0.5
    local lineA = math.floor(30 * activePct * pulse)
    nvgBeginPath(vg_)
    nvgRect(vg_, 2, 2, w - 4, h - 4)
    nvgStrokeColor(vg_, nvgRGBA(cr, cg, cb, lineA))
    nvgStrokeWidth(vg_, 1)
    nvgStroke(vg_)
end

-- ============================================================================
-- 冲刺动态模糊（NanoVG 径向渐变模拟，四边向中心渐变 + 中心清晰）
-- ============================================================================

function DrawComboMotionBlur(w, h, rushPct)
    -- rushPct: 0→1 (0=刚开始冲刺, 1=冲刺结束)
    -- 模糊强度：冲刺中间最强，开始和结束弱化
    local intensity = math.sin(rushPct * math.pi)  -- 0→1→0 bell curve
    local baseAlpha = math.floor(120 * intensity)
    if baseAlpha <= 0 then return end

    -- 径向模糊效果：多层半透明径向条纹从边缘向中心
    local cx = w * 0.5
    local cy = h * 0.5
    local maxR = math.sqrt(cx * cx + cy * cy)

    -- 外层模糊光晕（覆盖边缘区域，中心透明）
    local outerR = maxR * 1.1
    local innerR = maxR * 0.3

    local grad = nvgRadialGradient(vg_, cx, cy, innerR, outerR,
        nvgRGBA(10, 15, 30, 0),
        nvgRGBA(10, 15, 30, baseAlpha))
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, w, h)
    nvgFillPaint(vg_, grad)
    nvgFill(vg_)

    -- 第二层：更窄的径向模糊（增加层次感）
    local innerR2 = maxR * 0.4
    local outerR2 = maxR * 0.9
    local alpha2 = math.floor(60 * intensity)

    grad = nvgRadialGradient(vg_, cx, cy, innerR2, outerR2,
        nvgRGBA(20, 30, 60, 0),
        nvgRGBA(20, 30, 60, alpha2))
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, w, h)
    nvgFillPaint(vg_, grad)
    nvgFill(vg_)

    -- 边缘拉伸条纹（模拟运动模糊的方向性）
    local stripeCount = 12
    local stripeAlpha = math.floor(25 * intensity)
    if stripeAlpha > 0 then
        for i = 1, stripeCount do
            local angle = (i / stripeCount) * math.pi * 2
            -- 从边缘向中心的窄条
            local ex = cx + math.cos(angle) * maxR * 1.05
            local ey = cy + math.sin(angle) * maxR * 1.05
            local ix = cx + math.cos(angle) * maxR * 0.35
            local iy = cy + math.sin(angle) * maxR * 0.35

            local stripeGrad = nvgLinearGradient(vg_, ix, iy, ex, ey,
                nvgRGBA(150, 180, 255, 0),
                nvgRGBA(150, 180, 255, stripeAlpha))

            -- 计算条纹宽度的垂直方向
            local perpX = -math.sin(angle)
            local perpY = math.cos(angle)
            local halfW = maxR * 0.04

            nvgBeginPath(vg_)
            nvgMoveTo(vg_, ix + perpX * halfW, iy + perpY * halfW)
            nvgLineTo(vg_, ex + perpX * halfW * 2, ey + perpY * halfW * 2)
            nvgLineTo(vg_, ex - perpX * halfW * 2, ey - perpY * halfW * 2)
            nvgLineTo(vg_, ix - perpX * halfW, iy - perpY * halfW)
            nvgClosePath(vg_)
            nvgFillPaint(vg_, stripeGrad)
            nvgFill(vg_)
        end
    end
end

-- ============================================================================
-- 冲刺速度线条（密集、长、从屏幕边缘射向中心）
-- ============================================================================

local RUSH_LINE_COUNT = 56  -- 更多线条，比闪现更密

--- 生成冲刺线条（更长、更宽、更密，颜色偏青白）
local function generateRushLines()
    cachedRushLines_ = {}
    for i = 1, RUSH_LINE_COUNT do
        local edge = math.random(1, 4)
        local pos = math.random() * 1.0
        -- 比闪现线条更长
        local len = 0.12 + math.random() * 0.25
        local margin = math.random() * 0.02
        local width = 1.5 + math.random() * 3.5
        local alpha = 140 + math.random(115)
        -- 速度偏移（每条线有不同的延伸速度感）
        local speed = 0.5 + math.random() * 0.5

        table.insert(cachedRushLines_, {
            edge = edge,
            pos = pos,
            len = len,
            margin = margin,
            width = width,
            alpha = alpha,
            speed = speed,
        })
    end
end

function DrawComboRushLines(w, h, rushPct)
    -- rushPct: 0→1 (0=刚开始, 1=冲刺结束)

    -- 刚触发时生成线条
    if FirstPersonController.ComboRushJustFired() then
        generateRushLines()
    end

    if #cachedRushLines_ == 0 then return end

    local cx = w * 0.5
    local cy = h * 0.5
    -- 全程可见，但两端渐隐
    local globalAlpha = math.sin(rushPct * math.pi)  -- 0→1→0 bell curve

    for _, line in ipairs(cachedRushLines_) do
        local startX, startY

        if line.edge == 1 then
            startX = line.pos * w
            startY = line.margin * h
        elseif line.edge == 2 then
            startX = line.pos * w
            startY = h - line.margin * h
        elseif line.edge == 3 then
            startX = line.margin * w
            startY = line.pos * h
        else
            startX = w - line.margin * w
            startY = line.pos * h
        end

        local dx = cx - startX
        local dy = cy - startY
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist < 1 then dist = 1 end
        local nx = dx / dist
        local ny = dy / dist

        -- 线条随冲刺进度向内延伸（越冲越深入屏幕中心）
        local extend = rushPct * line.speed
        local lineLen = line.len * dist * (0.8 + extend * 0.5)

        -- 线条起点也随进度向内移动（营造穿越感）
        local inward = extend * 0.15
        local sx = startX + nx * dist * inward
        local sy = startY + ny * dist * inward
        local ex = sx + nx * lineLen
        local ey = sy + ny * lineLen

        local a = math.floor(line.alpha * globalAlpha)
        if a <= 0 then goto continue end

        -- 线条渐变：起点亮，终点（靠近中心）暗
        nvgBeginPath(vg_)
        nvgMoveTo(vg_, sx, sy)
        nvgLineTo(vg_, ex, ey)
        -- 青白色，与闪现的偏蓝白色一致但更亮
        nvgStrokeColor(vg_, nvgRGBA(180, 220, 255, a))
        nvgStrokeWidth(vg_, line.width)
        nvgLineCap(vg_, NVG_ROUND)
        nvgStroke(vg_)

        ::continue::
    end
end

-- ============================================================================
-- 闪现无敌帧特效 — 屏幕边缘蓝白闪烁 + 半透明护盾纹理
-- ============================================================================

function DrawDashInvincible(w, h, pct)
    -- pct: 1=刚触发, 0=结束

    -- 快速闪烁节奏（高频 sin 脉冲）
    local elapsed = (1 - pct) * (GameConfig.Player.DashInvDuration or 0.3)
    local pulse = 0.6 + 0.4 * math.abs(math.sin(elapsed * 20))

    local alpha = math.floor(pct * pulse * 80)  -- 最大约 80/255 的淡蓝

    -- 1) 屏幕边缘光晕（渐变从边缘到内部）
    local border = math.min(w, h) * 0.12

    -- 上边
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, w, border)
    nvgFillPaint(vg_, nvgLinearGradient(vg_,
        0, 0, 0, border,
        nvgRGBA(150, 210, 255, alpha),
        nvgRGBA(150, 210, 255, 0)
    ))
    nvgFill(vg_)

    -- 下边
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, h - border, w, border)
    nvgFillPaint(vg_, nvgLinearGradient(vg_,
        0, h, 0, h - border,
        nvgRGBA(150, 210, 255, alpha),
        nvgRGBA(150, 210, 255, 0)
    ))
    nvgFill(vg_)

    -- 左边
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, border, h)
    nvgFillPaint(vg_, nvgLinearGradient(vg_,
        0, 0, border, 0,
        nvgRGBA(150, 210, 255, alpha),
        nvgRGBA(150, 210, 255, 0)
    ))
    nvgFill(vg_)

    -- 右边
    nvgBeginPath(vg_)
    nvgRect(vg_, w - border, 0, border, h)
    nvgFillPaint(vg_, nvgLinearGradient(vg_,
        w, 0, w - border, 0,
        nvgRGBA(150, 210, 255, alpha),
        nvgRGBA(150, 210, 255, 0)
    ))
    nvgFill(vg_)

    -- 2) 中心"INVINCIBLE"闪现文字提示（仅刚触发时短暂显示）
    if pct > 0.6 and fontId_ >= 0 then
        local textAlpha = math.floor((pct - 0.6) / 0.4 * 200)
        nvgFontFace(vg_, "dashfont")
        nvgFontSize(vg_, 16)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(180, 230, 255, textAlpha))
        nvgText(vg_, w * 0.5, h * 0.38, "无敌")
    end
end

return DashHUD
