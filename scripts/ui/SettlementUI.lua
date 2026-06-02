-- ============================================================================
-- SettlementUI.lua — 出征结算确认界面
-- 返回安全区时弹出，选择结算（角色重置）或继续战斗（禁入安全区）
-- ============================================================================

local DifficultySystem = require("systems.DifficultySystem")
local UI = require("urhox-libs/UI")
local UIHelper = require("ui.UIHelper")

local SettlementUI = {}

local root_ = nil
local bodyPanel_ = nil
local onSettle_ = nil   -- 结算回调: cb(summary)
local onDecline_ = nil  -- 拒绝回调: cb()

-- ============================================================================
-- 初始化
-- ============================================================================

---@return table UI 面板
function SettlementUI.Init()
    bodyPanel_ = UI.Panel {
        id = "settlementBody",
        width = "100%",
        marginBottom = 16,
    }

    root_ = UI.Panel {
        id = "settlementOverlay",
        position = "absolute",
        left = 0, right = 0, top = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = { 0, 0, 0, 180 },
        visible = false,
        children = {
            UI.Panel {
                width = 320,
                backgroundColor = { 15, 12, 30, 240 },
                borderRadius = 16,
                borderWidth = 2,
                borderColor = { 100, 180, 255, 150 },
                padding = { 20, 24 },
                alignItems = "center",
                children = {
                    UI.Label {
                        text = "出征结算",
                        fontSize = 24,
                        fontWeight = "bold",
                        fontColor = { 255, 220, 80, 255 },
                        marginBottom = 6,
                    },
                    UI.Label {
                        id = "settleDiffLabel",
                        text = "",
                        fontSize = 13,
                        fontColor = { 160, 160, 180, 180 },
                        marginBottom = 16,
                    },
                    bodyPanel_,
                    UI.Label {
                        text = "结算后角色将重置为初始状态\n获得的金币和水晶将保留",
                        fontSize = 12,
                        fontColor = { 255, 180, 100, 180 },
                        textAlign = "center",
                        marginBottom = 20,
                    },
                    UI.Panel {
                        flexDirection = "row",
                        justifyContent = "center",
                        children = {
                            UI.Button {
                                text = "结算并回归",
                                fontSize = 15,
                                width = 130,
                                height = 40,
                                variant = "primary",
                                borderRadius = 20,
                                marginRight = 12,
                                onClick = function()
                                    local cb = onSettle_
                                    SettlementUI.Hide()
                                    if cb then cb() end
                                end,
                            },
                            UI.Button {
                                text = "继续战斗",
                                fontSize = 15,
                                width = 130,
                                height = 40,
                                variant = "outline",
                                borderRadius = 20,
                                onClick = function()
                                    local cb = onDecline_
                                    SettlementUI.Hide()
                                    if cb then cb() end
                                end,
                            },
                        },
                    },
                },
            },
        },
    }

    print("[SettlementUI] 初始化完成")
    return root_
end

-- ============================================================================
-- 显示 / 隐藏
-- ============================================================================

---@param expeditionData table { killCount, goldEarned, crystalEarned, departureTime }
---@param onSettle function() 结算回调
---@param onDecline function() 拒绝回调
function SettlementUI.Show(expeditionData, onSettle, onDecline)
    onSettle_ = onSettle
    onDecline_ = onDecline

    -- 填充出征数据
    if bodyPanel_ then
        UIHelper.DestroyChildren(bodyPanel_)

        local duration = os.clock() - (expeditionData.departureTime or os.clock())
        local minutes = math.floor(duration / 60)
        local seconds = math.floor(duration % 60)

        -- 当前难度
        local diffLabel = root_:FindById("settleDiffLabel")
        if diffLabel then
            local cfg = DifficultySystem.GetConfig()
            diffLabel:SetText("当前难度: " .. cfg.icon .. " " .. cfg.name)
            local clr = cfg.color
            diffLabel:SetStyle({ fontColor = { clr[1], clr[2], clr[3], 220 } })
        end

        local lines = {
            { icon = "⏱", label = "出征时长", value = string.format("%d:%02d", minutes, seconds) },
            { icon = "💀", label = "击杀数",   value = tostring(expeditionData.killCount or 0) },
            { icon = "💰", label = "获得金币", value = "+" .. tostring(expeditionData.goldEarned or 0) },
            { icon = "💎", label = "获得水晶", value = "+" .. tostring(expeditionData.crystalEarned or 0) },
            { icon = "🩸", label = "受到伤害", value = tostring(expeditionData.damageTaken or 0) },
        }

        for _, line in ipairs(lines) do
            bodyPanel_:AddChild(UI.Panel {
                flexDirection = "row",
                justifyContent = "space-between",
                width = "100%",
                marginBottom = 6,
                children = {
                    UI.Label {
                        text = line.icon .. " " .. line.label,
                        fontSize = 13,
                        fontColor = { 200, 200, 220, 220 },
                    },
                    UI.Label {
                        text = line.value,
                        fontSize = 13,
                        fontWeight = "bold",
                        fontColor = { 255, 255, 255, 255 },
                    },
                },
            })
        end
    end

    if root_ then root_:Show() end
end

function SettlementUI.Hide()
    if root_ then root_:Hide() end
    onSettle_ = nil
    onDecline_ = nil
end

function SettlementUI.IsVisible()
    return root_ and root_:IsVisible() or false
end

return SettlementUI
