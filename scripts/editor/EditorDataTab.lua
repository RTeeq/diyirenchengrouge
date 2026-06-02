-- ============================================================================
-- EditorDataTab.lua — 角色(NPC+对话) / 物品 / 设置 编辑面板
-- 使用 Accordion 折叠分组，Modal.Confirm 二次确认危险操作
-- ============================================================================

local GameConfig = require("config.GameConfig")
local NPCManager = require("world.NPCManager")
local ItemSpawner = require("world.ItemSpawner")
local QuestData = require("data.QuestData")
local AudioManager = require("core.AudioManager")
local UI = require("urhox-libs/UI")
local UIHelper = require("ui.UIHelper")

local EditorDataTab = {}

---@type Scene
local scene_ = nil
local fpController_ = nil

-- 覆盖记录
local npcOverrides_ = {}
local dialogueOverrides_ = {}
local itemOverrides_ = {}
local settingsOverrides_ = {}

-- NPC 角色描述（来自剧情设计）
local NPC_DESCRIPTIONS = {
    [GameConfig.NPCs.AYANG]     = { role = "玩家的好友", trait = "热情开朗", desc = "阿晨最好的朋友，从小一起长大，是村子里最活泼的年轻人。" },
    [GameConfig.NPCs.QIQI]      = { role = "神秘少女 · 引导者", trait = "神秘淡然", desc = "能被极少数人看到的神秘存在，似乎知道很多关于村子的秘密。" },
    [GameConfig.NPCs.WENGMOLAO]  = { role = "村里术士", trait = "博学神秘", desc = "精通各种奇术和古老知识的老人，村里人敬畏地称呼他为嗡摩佬。" },
    [GameConfig.NPCs.TUDI_SHEN]  = { role = "村庄守护者", trait = "威严慈祥", desc = "守护山根一方的土地神，只有持平安玉的人才能看到他。" },
    [GameConfig.NPCs.CUNZHANG]   = { role = "村庄管理者", trait = "稳重谨慎", desc = "罗坪村的村长，了解村子里的大小事务，对庙宇之事讳莫如深。" },
}

-- 任务物品（只通过对话获得，不在场景中生成）
local QUEST_ONLY_ITEMS = {
    GameConfig.Items.PEACE_JADE,
    GameConfig.Items.BAGUA_MIRROR,
    GameConfig.Items.OPENED_SCROLL,
    GameConfig.Items.HOLY_WATER,
}

-- ============================================================================
-- ===  角色 Tab（NPC + 对话 合并）  ==========================================
-- ============================================================================

-- NPC 列表
local npcListPanel_ = nil
local selectedNpcId_ = nil
local charAccordion_ = nil

-- NPC 属性
local npcSelectedLabel_ = nil
local npcRoleLabel_ = nil
local npcTraitLabel_ = nil
local npcDescLabel_ = nil
local npcDialogueStatsLabel_ = nil
local npcGiftItemsLabel_ = nil
local npcPosXField_ = nil
local npcPosYField_ = nil
local npcPosZField_ = nil
local npcScaleSlider_ = nil
local npcScaleLabel_ = nil
local npcBodyColorPicker_ = nil
local npcHeadColorPicker_ = nil
local npcHairColorPicker_ = nil

-- 对话
local dialogueStageDropdown_ = nil
local dialogueListPanel_ = nil
local currentDialogueStage_ = 0

-- ─── NPC 属性：apply / select ───────────────────────────────────────────────

local function applyNPCChanges()
    if not selectedNpcId_ then return end

    local node = NPCManager.GetNode(selectedNpcId_)
    if not node then return end

    -- 位置
    local px = tonumber(npcPosXField_:GetValue()) or node.position.x
    local py = tonumber(npcPosYField_:GetValue()) or 0
    local pz = tonumber(npcPosZField_:GetValue()) or node.position.z
    NPCManager.UpdateNPCTransform(selectedNpcId_, Vector3(px, py, pz))

    -- 缩放
    local npcScale = (npcScaleSlider_ and npcScaleSlider_:GetValue() or 100) / 100
    local configs = NPCManager.GetConfigs()
    local cfg = configs[selectedNpcId_]
    if cfg then
        cfg.scale = npcScale
        local bodyNode = node:GetChild("Body")
        if bodyNode then bodyNode.scale = Vector3(0.5 * npcScale, 1.4 * npcScale, 0.35 * npcScale) end
        local headNode = node:GetChild("Head")
        if headNode then headNode.scale = Vector3(0.35 * npcScale, 0.35 * npcScale, 0.35 * npcScale) end
        local hairNode = node:GetChild("Hair")
        if hairNode then hairNode.scale = Vector3(0.38 * npcScale, 0.22 * npcScale, 0.38 * npcScale) end
    end

    -- 颜色
    local GameEditor = require("editor.GameEditor")
    local bodyRGBA = npcBodyColorPicker_:GetValue()
    local headRGBA = npcHeadColorPicker_:GetValue()
    local hairRGBA = npcHairColorPicker_:GetValue()

    local bodyNode = node:GetChild("Body")
    if bodyNode then
        local m = bodyNode:GetComponent("StaticModel")
        if m then m:SetMaterial(GameConfig.CreateMaterial(GameEditor.RGBAToColor(bodyRGBA))) end
    end
    local headNode = node:GetChild("Head")
    if headNode then
        local m = headNode:GetComponent("StaticModel")
        if m then m:SetMaterial(GameConfig.CreateMaterial(GameEditor.RGBAToColor(headRGBA))) end
    end
    local hairNode = node:GetChild("Hair")
    if hairNode then
        local m = hairNode:GetComponent("StaticModel")
        if m then m:SetMaterial(GameConfig.CreateMaterial(GameEditor.RGBAToColor(hairRGBA))) end
    end

    -- 记录覆盖
    local bc = GameEditor.RGBAToColor(bodyRGBA)
    local hc = GameEditor.RGBAToColor(headRGBA)
    local hrc = GameEditor.RGBAToColor(hairRGBA)
    npcOverrides_[selectedNpcId_] = {
        pos = { px, py, pz },
        scale = npcScale,
        bodyColor = { bc.r, bc.g, bc.b, bc.a },
        headColor = { hc.r, hc.g, hc.b, hc.a },
        hairColor = { hrc.r, hrc.g, hrc.b, hrc.a },
    }
end

local function refreshDialogueList()  -- forward declaration; body below
end

local function selectNPC(npcId)
    selectedNpcId_ = npcId
    local configs = NPCManager.GetConfigs()
    local cfg = configs[npcId]
    if not cfg then return end

    local node = NPCManager.GetNode(npcId)
    if not node then return end

    if npcSelectedLabel_ then npcSelectedLabel_:SetText("NPC: " .. cfg.name) end

    -- 填充角色信息
    local npcInfo = NPC_DESCRIPTIONS[npcId]
    if npcInfo then
        if npcRoleLabel_ then npcRoleLabel_:SetText(npcInfo.role) end
        if npcTraitLabel_ then npcTraitLabel_:SetText("性格: " .. npcInfo.trait) end
        if npcDescLabel_ then npcDescLabel_:SetText(npcInfo.desc) end
    end

    -- 对话统计
    local npcDialogues = QuestData.Dialogues[npcId]
    if npcDialogues and npcDialogueStatsLabel_ then
        local stageCount = 0
        local totalLines = 0
        local giftItems = {}
        for stage, lines in pairs(npcDialogues) do
            stageCount = stageCount + 1
            totalLines = totalLines + #lines
            for _, line in ipairs(lines) do
                if line.giveItem then
                    local itemInfo = QuestData.GetItemInfo(line.giveItem)
                    local itemName = itemInfo and itemInfo.name or line.giveItem
                    giftItems[itemName] = true
                end
            end
        end
        npcDialogueStatsLabel_:SetText(stageCount .. " 个阶段 · " .. totalLines .. " 行对话")

        local giftList = {}
        for name, _ in pairs(giftItems) do table.insert(giftList, name) end
        if npcGiftItemsLabel_ then
            if #giftList > 0 then
                npcGiftItemsLabel_:SetText("赠送: " .. table.concat(giftList, "、"))
            else
                npcGiftItemsLabel_:SetText("赠送: 无")
            end
        end
    end

    -- 填充属性
    npcPosXField_:SetValue(string.format("%.2f", node.position.x))
    npcPosYField_:SetValue(string.format("%.2f", node.position.y))
    npcPosZField_:SetValue(string.format("%.2f", node.position.z))

    local scaleVal = math.floor((cfg.scale or 1.0) * 100 + 0.5)
    npcScaleSlider_:SetValue(scaleVal)
    npcScaleLabel_:SetText("缩放: " .. scaleVal .. "%")

    local GameEditor = require("editor.GameEditor")
    npcBodyColorPicker_:SetValue(GameEditor.ColorToRGBA(cfg.bodyColor))
    npcHeadColorPicker_:SetValue(GameEditor.ColorToRGBA(cfg.headColor))
    npcHairColorPicker_:SetValue(GameEditor.ColorToRGBA(cfg.hairColor))

    -- 自动展开属性和对话 section
    if charAccordion_ then
        charAccordion_:ExpandItem("props")
        charAccordion_:ExpandItem("dialogue")
    end

    -- 刷新对话列表
    refreshDialogueList()
end

-- ─── NPC 列表 ────────────────────────────────────────────────────────────────

local function refreshNPCList()
    if not npcListPanel_ then return end
    UIHelper.DestroyChildren(npcListPanel_)

    local configs = NPCManager.GetConfigs()
    for npcId, cfg in pairs(configs) do
        local btn = UI.Button {
            text = cfg.name .. " (" .. npcId .. ")",
            fontSize = 11,
            backgroundColor = { 40, 40, 55, 255 },
            hoverBackgroundColor = { 55, 55, 75, 255 },
            textColor = { 200, 200, 210, 255 },
            paddingVertical = 4,
            paddingHorizontal = 8,
            onClick = function(self)
                selectNPC(npcId)
            end,
        }
        npcListPanel_:AddChild(btn)
    end
end

local function buildNPCListContent()
    npcSelectedLabel_ = UI.Label {
        text = "选择一个 NPC",
        fontSize = 12,
        fontColor = { 200, 180, 120, 255 },
        marginBottom = 6,
    }
    npcListPanel_ = UI.Panel { gap = 3 }

    return UI.Panel {
        children = {
            npcSelectedLabel_,
            UI.ScrollView {
                maxHeight = 180,
                showScrollbar = true,
                padding = 4,
                children = { npcListPanel_ },
            },
        },
    }
end

-- ─── NPC 属性 ────────────────────────────────────────────────────────────────

local function buildNPCPropsContent()
    -- 角色设定（只读展示）
    npcRoleLabel_ = UI.Label {
        text = "—", fontSize = 13, fontWeight = "bold",
        fontColor = { 255, 210, 130, 255 }, marginBottom = 2,
    }
    npcTraitLabel_ = UI.Label {
        text = "性格: —", fontSize = 11,
        fontColor = { 180, 200, 150, 255 }, marginBottom = 2,
    }
    npcDescLabel_ = UI.Label {
        text = "请选择一个NPC查看角色设定", fontSize = 11,
        fontColor = { 170, 170, 185, 220 }, marginBottom = 4,
    }
    npcDialogueStatsLabel_ = UI.Label {
        text = "— 个阶段 · — 行对话", fontSize = 10,
        fontColor = { 130, 170, 220, 200 }, marginBottom = 2,
    }
    npcGiftItemsLabel_ = UI.Label {
        text = "赠送: —", fontSize = 10,
        fontColor = { 130, 170, 220, 200 }, marginBottom = 4,
    }

    local infoBox = UI.Panel {
        backgroundColor = { 30, 35, 50, 200 },
        borderRadius = 6,
        padding = 8,
        marginBottom = 8,
        children = {
            UI.Label { text = "角色设定", fontSize = 10, fontWeight = "bold", fontColor = { 100, 100, 120, 200 }, marginBottom = 4 },
            npcRoleLabel_,
            npcTraitLabel_,
            npcDescLabel_,
            UI.Panel { height = 1, backgroundColor = { 60, 60, 80, 150 }, marginVertical = 4 },
            npcDialogueStatsLabel_,
            npcGiftItemsLabel_,
        },
    }

    -- 可编辑属性
    npcPosXField_ = UI.TextField { value = "0", fontSize = 12, flexGrow = 1, flexBasis = 0,
        onSubmit = function() applyNPCChanges() end, onBlur = function() applyNPCChanges() end }
    npcPosYField_ = UI.TextField { value = "0", fontSize = 12, flexGrow = 1, flexBasis = 0,
        onSubmit = function() applyNPCChanges() end, onBlur = function() applyNPCChanges() end }
    npcPosZField_ = UI.TextField { value = "0", fontSize = 12, flexGrow = 1, flexBasis = 0,
        onSubmit = function() applyNPCChanges() end, onBlur = function() applyNPCChanges() end }

    npcScaleLabel_ = UI.Label { text = "缩放: 100%", fontSize = 12, fontColor = { 160, 160, 170, 255 }, marginBottom = 4 }
    npcScaleSlider_ = UI.Slider {
        value = 100, min = 50, max = 150, step = 1,
        onChange = function(self, val)
            if npcScaleLabel_ then npcScaleLabel_:SetText("缩放: " .. val .. "%") end
        end,
        onChangeEnd = function(self, val)
            if npcScaleLabel_ then npcScaleLabel_:SetText("缩放: " .. val .. "%") end
            applyNPCChanges()
        end,
    }

    npcBodyColorPicker_ = UI.ColorPicker { value = { 200, 200, 200, 255 }, showAlpha = false,
        onChange = function() applyNPCChanges() end }
    npcHeadColorPicker_ = UI.ColorPicker { value = { 200, 200, 200, 255 }, showAlpha = false,
        onChange = function() applyNPCChanges() end }
    npcHairColorPicker_ = UI.ColorPicker { value = { 200, 200, 200, 255 }, showAlpha = false,
        onChange = function() applyNPCChanges() end }

    return UI.Panel {
        children = {
            infoBox,
            UI.Label { text = "位置", fontSize = 11, fontWeight = "bold", fontColor = { 140, 180, 220, 255 }, marginBottom = 4 },
            UI.Panel { flexDirection = "row", gap = 4, marginBottom = 4, children = {
                UI.Label { text = "X", fontSize = 11, fontColor = { 160, 160, 170, 255 }, width = 16 },
                npcPosXField_,
                UI.Label { text = "Y", fontSize = 11, fontColor = { 160, 160, 170, 255 }, width = 16 },
                npcPosYField_,
                UI.Label { text = "Z", fontSize = 11, fontColor = { 160, 160, 170, 255 }, width = 16 },
                npcPosZField_,
            }},
            npcScaleLabel_,
            npcScaleSlider_,
            UI.Label { text = "身体颜色", fontSize = 11, fontColor = { 160, 160, 170, 255 }, marginTop = 6, marginBottom = 2 },
            npcBodyColorPicker_,
            UI.Label { text = "头部颜色", fontSize = 11, fontColor = { 160, 160, 170, 255 }, marginTop = 6, marginBottom = 2 },
            npcHeadColorPicker_,
            UI.Label { text = "头发颜色", fontSize = 11, fontColor = { 160, 160, 170, 255 }, marginTop = 6, marginBottom = 2 },
            npcHairColorPicker_,
        },
    }
end

-- ─── 对话编辑 ────────────────────────────────────────────────────────────────

function EditorDataTab.RecordDialogueOverride()
    if not selectedNpcId_ then return end

    local npcDialogues = QuestData.Dialogues[selectedNpcId_]
    if not npcDialogues then return end

    local stageDialogue = npcDialogues[currentDialogueStage_]
    if not stageDialogue then return end

    if not dialogueOverrides_[selectedNpcId_] then
        dialogueOverrides_[selectedNpcId_] = {}
    end

    local lines = {}
    for _, line in ipairs(stageDialogue) do
        local entry = { speaker = line.speaker, text = line.text }
        if line.giveItem then entry.giveItem = line.giveItem end
        if line.choices then entry.choices = line.choices end
        table.insert(lines, entry)
    end
    dialogueOverrides_[selectedNpcId_][tostring(currentDialogueStage_)] = lines
end

-- 实际的 refreshDialogueList 实现（覆盖前面的空函数）
refreshDialogueList = function()
    if not dialogueListPanel_ then return end
    UIHelper.DestroyChildren(dialogueListPanel_)

    if not selectedNpcId_ then
        dialogueListPanel_:AddChild(UI.Label {
            text = "请先选择 NPC",
            fontSize = 11,
            fontColor = { 140, 140, 140, 200 },
        })
        return
    end

    local npcDialogues = QuestData.Dialogues[selectedNpcId_]
    if not npcDialogues then return end

    local stageDialogue = npcDialogues[currentDialogueStage_]
    if not stageDialogue then
        dialogueListPanel_:AddChild(UI.Label {
            text = "此阶段无对话",
            fontSize = 11,
            fontColor = { 140, 140, 140, 200 },
        })
        return
    end

    for i, line in ipairs(stageDialogue) do
        local idx = i

        local speakerField = UI.TextField {
            value = line.speaker or "",
            fontSize = 11,
            placeholder = "说话者",
            width = 55,
            onBlur = function(self)
                stageDialogue[idx].speaker = self:GetValue()
                EditorDataTab.RecordDialogueOverride()
            end,
        }

        local textField = UI.TextField {
            value = line.text or "",
            fontSize = 11,
            placeholder = "对话内容",
            flexGrow = 1,
            flexBasis = 0,
            onBlur = function(self)
                stageDialogue[idx].text = self:GetValue()
                EditorDataTab.RecordDialogueOverride()
            end,
        }

        local giveItemField = UI.TextField {
            value = line.giveItem or "",
            fontSize = 11,
            placeholder = "给予物品",
            width = 60,
            onBlur = function(self)
                local val = self:GetValue()
                stageDialogue[idx].giveItem = (val ~= "") and val or nil
                EditorDataTab.RecordDialogueOverride()
            end,
        }

        local deleteBtn = UI.Button {
            text = "X",
            fontSize = 10,
            width = 22, height = 22,
            backgroundColor = { 120, 40, 40, 255 },
            hoverBackgroundColor = { 160, 50, 50, 255 },
            textColor = { 255, 200, 200, 255 },
            paddingHorizontal = 0,
            paddingVertical = 0,
            onClick = function(self)
                UI.Modal.Confirm({
                    title = "删除对话",
                    message = "确定删除第 " .. idx .. " 行对话？",
                    onConfirm = function()
                        table.remove(stageDialogue, idx)
                        EditorDataTab.RecordDialogueOverride()
                        refreshDialogueList()
                        UI.Toast.Show("已删除第 " .. idx .. " 行", { variant = "info", duration = 1.5 })
                    end,
                })
            end,
        }

        dialogueListPanel_:AddChild(UI.Panel {
            flexDirection = "row",
            gap = 3,
            marginBottom = 3,
            alignItems = "center",
            children = {
                UI.Label { text = "#" .. i, fontSize = 10, fontColor = { 100, 100, 110, 200 }, width = 18 },
                speakerField,
                textField,
                giveItemField,
                deleteBtn,
            },
        })
    end
end

local function buildDialogueContent()
    dialogueStageDropdown_ = UI.Dropdown {
        options = {
            { value = 0, label = "阶段 0" },
            { value = 1, label = "阶段 1" },
            { value = 2, label = "阶段 2" },
        },
        value = 0,
        fontSize = 12,
        onChange = function(self, value)
            currentDialogueStage_ = value
            refreshDialogueList()
        end,
    }

    dialogueListPanel_ = UI.Panel { gap = 2 }

    local addLineBtn = UI.Button {
        text = "+ 添加对话",
        fontSize = 11,
        variant = "primary",
        marginTop = 6,
        onClick = function()
            if not selectedNpcId_ then
                UI.Toast.Show("请先选择NPC", { variant = "warning", duration = 2 })
                return
            end

            local npcDialogues = QuestData.Dialogues[selectedNpcId_]
            if not npcDialogues then
                npcDialogues = {}
                QuestData.Dialogues[selectedNpcId_] = npcDialogues
            end

            if not npcDialogues[currentDialogueStage_] then
                npcDialogues[currentDialogueStage_] = {}
            end

            local cfgs = NPCManager.GetConfigs()
            local npcCfg = cfgs[selectedNpcId_]
            local defaultSpeaker = npcCfg and npcCfg.name or "???"

            table.insert(npcDialogues[currentDialogueStage_], {
                speaker = defaultSpeaker,
                text = "新对话内容",
            })

            EditorDataTab.RecordDialogueOverride()
            refreshDialogueList()
            UI.Toast.Show("已添加对话", { variant = "success", duration = 1.5 })
        end,
    }

    return UI.Panel {
        children = {
            UI.Label { text = "任务阶段", fontSize = 11, fontColor = { 160, 160, 170, 255 }, marginBottom = 4 },
            dialogueStageDropdown_,
            UI.Panel { height = 1, backgroundColor = { 50, 50, 60, 255 }, marginVertical = 6 },
            UI.ScrollView {
                maxHeight = 250,
                showScrollbar = true,
                padding = 4,
                children = { dialogueListPanel_ },
            },
            addLineBtn,
        },
    }
end

-- ─── 创建角色面板 ────────────────────────────────────────────────────────────

function EditorDataTab.CreateCharacterPanel()
    local npcListContent = buildNPCListContent()
    local npcPropsContent = buildNPCPropsContent()
    local dialogueContent = buildDialogueContent()

    charAccordion_ = UI.Accordion {
        items = {
            { id = "list",     title = "NPC 列表",  content = npcListContent,  defaultExpanded = true },
            { id = "props",    title = "NPC 属性",  content = npcPropsContent, defaultExpanded = false },
            { id = "dialogue", title = "NPC 对话",  content = dialogueContent, defaultExpanded = false },
        },
        allowMultiple = true,
        variant = "outlined",
        animationDuration = 0.15,
    }

    return UI.Panel {
        flexGrow = 1,
        flexBasis = 0,
        children = {
            UI.ScrollView {
                flexGrow = 1,
                flexBasis = 0,
                padding = 8,
                children = { charAccordion_ },
            },
        },
    }
end

-- ============================================================================
-- ===  物品 Tab  ==============================================================
-- ============================================================================

local itemListPanel_ = nil
local itemSelectedLabel_ = nil
local selectedItemId_ = nil
local itemAccordion_ = nil

local itemNameLabel_ = nil
local itemDescLabel_ = nil
local itemHintLabel_ = nil

local itemPosXField_ = nil
local itemPosYField_ = nil
local itemPosZField_ = nil
local itemScaleXField_ = nil
local itemScaleYField_ = nil
local itemScaleZField_ = nil
local itemModelDropdown_ = nil
local itemColorPicker_ = nil
local itemEmissiveToggle_ = nil
local itemBobSlider_ = nil
local itemBobLabel_ = nil

local ITEM_MODEL_OPTIONS = {
    { value = "Models/Box.mdl",      label = "方块" },
    { value = "Models/Sphere.mdl",   label = "球体" },
    { value = "Models/Cylinder.mdl", label = "圆柱" },
    { value = "Models/Pyramid.mdl",  label = "金字塔" },
}

local function applyItemChanges()
    if not selectedItemId_ then return end

    local configs = ItemSpawner.GetConfigs()
    local cfg = configs[selectedItemId_]
    if not cfg then return end

    local node = ItemSpawner.GetNode(selectedItemId_)
    if not node then return end

    -- 位置
    local px = tonumber(itemPosXField_:GetValue()) or cfg.pos.x
    local py = tonumber(itemPosYField_:GetValue()) or cfg.pos.y
    local pz = tonumber(itemPosZField_:GetValue()) or cfg.pos.z
    ItemSpawner.UpdateItemTransform(selectedItemId_, Vector3(px, py, pz))

    -- 模型
    local modelPath = itemModelDropdown_:GetValue() or cfg.model
    cfg.model = modelPath

    -- 颜色
    local GameEditor = require("editor.GameEditor")
    local rgba = itemColorPicker_:GetValue() or { 200, 200, 200, 255 }
    local color = GameEditor.RGBAToColor(rgba)
    cfg.color = color

    -- 发光
    local emissive = itemEmissiveToggle_:GetValue()
    cfg.emissive = emissive

    -- bob
    local bob = (itemBobSlider_:GetValue() or 15) / 100
    cfg.bobHeight = bob

    -- 缩放
    local sx = tonumber(itemScaleXField_:GetValue()) or (cfg.scale and cfg.scale.x or 1)
    local sy = tonumber(itemScaleYField_:GetValue()) or (cfg.scale and cfg.scale.y or 1)
    local sz = tonumber(itemScaleZField_:GetValue()) or (cfg.scale and cfg.scale.z or 1)
    cfg.scale = Vector3(sx, sy, sz)

    -- 更新 Inner 子节点
    local inner = node:GetChild("Inner")
    if inner then
        inner.scale = Vector3(sx, sy, sz)
        local model = inner:GetComponent("StaticModel")
        if model then
            model:SetModel(cache:GetResource("Model", modelPath))
            if emissive then
                model:SetMaterial(GameConfig.CreateEmissiveMaterial(color, 1.5))
            else
                model:SetMaterial(GameConfig.CreateMaterial(color))
            end
        end
    end

    -- 记录覆盖
    itemOverrides_[selectedItemId_] = {
        pos = { px, py, pz },
        scale = { sx, sy, sz },
        model = modelPath,
        color = { color.r, color.g, color.b, color.a },
        emissive = emissive,
        bobHeight = bob,
    }
end

local function selectItem(itemId)
    selectedItemId_ = itemId
    local configs = ItemSpawner.GetConfigs()
    local cfg = configs[itemId]
    if not cfg then return end

    local itemInfo = QuestData.GetItemInfo(itemId)
    local displayName = itemInfo and itemInfo.name or itemId

    if itemSelectedLabel_ then itemSelectedLabel_:SetText("物品: " .. displayName) end

    -- 填充物品信息
    if itemInfo then
        if itemNameLabel_ then itemNameLabel_:SetText(itemInfo.name) end
        if itemDescLabel_ then itemDescLabel_:SetText(itemInfo.desc) end
        if itemHintLabel_ then itemHintLabel_:SetText(itemInfo.hint) end
    else
        if itemNameLabel_ then itemNameLabel_:SetText(itemId) end
        if itemDescLabel_ then itemDescLabel_:SetText("无描述") end
        if itemHintLabel_ then itemHintLabel_:SetText("无提示") end
    end

    itemPosXField_:SetValue(string.format("%.2f", cfg.pos.x))
    itemPosYField_:SetValue(string.format("%.2f", cfg.pos.y))
    itemPosZField_:SetValue(string.format("%.2f", cfg.pos.z))

    local scl = cfg.scale or Vector3(1, 1, 1)
    itemScaleXField_:SetValue(string.format("%.2f", scl.x))
    itemScaleYField_:SetValue(string.format("%.2f", scl.y))
    itemScaleZField_:SetValue(string.format("%.2f", scl.z))

    itemModelDropdown_:SetValue(cfg.model)

    local GameEditor = require("editor.GameEditor")
    itemColorPicker_:SetValue(GameEditor.ColorToRGBA(cfg.color))
    itemEmissiveToggle_:SetValue(cfg.emissive or false)

    local bob = math.floor((cfg.bobHeight or 0.1) * 100 + 0.5)
    itemBobSlider_:SetValue(bob)
    itemBobLabel_:SetText("浮动: " .. bob .. "%")

    -- 自动展开属性
    if itemAccordion_ then
        itemAccordion_:ExpandItem("props")
    end
end

local function refreshItemList()
    if not itemListPanel_ then return end
    UIHelper.DestroyChildren(itemListPanel_)

    local configs = ItemSpawner.GetConfigs()
    for itemId, cfg in pairs(configs) do
        local itemInfo = QuestData.GetItemInfo(itemId)
        local displayName = itemInfo and itemInfo.name or itemId

        local btn = UI.Button {
            text = displayName,
            fontSize = 11,
            backgroundColor = { 40, 40, 55, 255 },
            hoverBackgroundColor = { 55, 55, 75, 255 },
            textColor = { 200, 200, 210, 255 },
            paddingVertical = 4,
            paddingHorizontal = 8,
            onClick = function(self)
                selectItem(itemId)
            end,
        }
        itemListPanel_:AddChild(btn)
    end
end

local function buildItemListContent()
    itemSelectedLabel_ = UI.Label {
        text = "选择一个物品",
        fontSize = 12,
        fontColor = { 200, 180, 120, 255 },
        marginBottom = 6,
    }
    itemListPanel_ = UI.Panel { gap = 3 }

    return UI.Panel {
        children = {
            itemSelectedLabel_,
            UI.ScrollView {
                maxHeight = 180,
                showScrollbar = true,
                padding = 4,
                children = { itemListPanel_ },
            },
        },
    }
end

local function buildItemPropsContent()
    -- 物品信息（只读展示）
    itemNameLabel_ = UI.Label {
        text = "—", fontSize = 13, fontWeight = "bold",
        fontColor = { 255, 210, 130, 255 }, marginBottom = 2,
    }
    itemDescLabel_ = UI.Label {
        text = "请选择一个物品查看详情", fontSize = 11,
        fontColor = { 170, 170, 185, 220 }, marginBottom = 2,
    }
    itemHintLabel_ = UI.Label {
        text = "", fontSize = 10,
        fontColor = { 140, 200, 160, 200 }, marginBottom = 4,
    }

    local itemInfoBox = UI.Panel {
        backgroundColor = { 30, 35, 50, 200 },
        borderRadius = 6,
        padding = 8,
        marginBottom = 8,
        children = {
            UI.Label { text = "物品图鉴", fontSize = 10, fontWeight = "bold", fontColor = { 100, 100, 120, 200 }, marginBottom = 4 },
            itemNameLabel_,
            itemDescLabel_,
            itemHintLabel_,
        },
    }

    itemPosXField_ = UI.TextField { value = "0", fontSize = 12, flexGrow = 1, flexBasis = 0,
        onSubmit = function() applyItemChanges() end, onBlur = function() applyItemChanges() end }
    itemPosYField_ = UI.TextField { value = "0", fontSize = 12, flexGrow = 1, flexBasis = 0,
        onSubmit = function() applyItemChanges() end, onBlur = function() applyItemChanges() end }
    itemPosZField_ = UI.TextField { value = "0", fontSize = 12, flexGrow = 1, flexBasis = 0,
        onSubmit = function() applyItemChanges() end, onBlur = function() applyItemChanges() end }

    itemScaleXField_ = UI.TextField { value = "1.00", fontSize = 12, flexGrow = 1, flexBasis = 0,
        onSubmit = function() applyItemChanges() end, onBlur = function() applyItemChanges() end }
    itemScaleYField_ = UI.TextField { value = "1.00", fontSize = 12, flexGrow = 1, flexBasis = 0,
        onSubmit = function() applyItemChanges() end, onBlur = function() applyItemChanges() end }
    itemScaleZField_ = UI.TextField { value = "1.00", fontSize = 12, flexGrow = 1, flexBasis = 0,
        onSubmit = function() applyItemChanges() end, onBlur = function() applyItemChanges() end }

    itemModelDropdown_ = UI.Dropdown {
        options = ITEM_MODEL_OPTIONS,
        value = "Models/Box.mdl",
        fontSize = 12,
        onChange = function(self, value) applyItemChanges() end,
    }

    itemColorPicker_ = UI.ColorPicker {
        value = { 200, 200, 200, 255 },
        showAlpha = false,
        onChange = function() applyItemChanges() end,
    }

    itemEmissiveToggle_ = UI.Toggle {
        checked = false,
        onChange = function() applyItemChanges() end,
    }

    itemBobLabel_ = UI.Label { text = "浮动: 15%", fontSize = 11, fontColor = { 160, 160, 170, 255 }, marginBottom = 4 }
    itemBobSlider_ = UI.Slider {
        value = 15, min = 0, max = 50, step = 1,
        onChange = function(self, val)
            itemBobLabel_:SetText("浮动: " .. val .. "%")
        end,
        onChangeEnd = function(self, val) applyItemChanges() end,
    }

    -- 传送按钮
    local teleportBtn = UI.Button {
        text = "传送到物品位置",
        fontSize = 11,
        variant = "secondary",
        marginTop = 6,
        onClick = function()
            if not selectedItemId_ then return end
            local cfgs = ItemSpawner.GetConfigs()
            local cfg = cfgs[selectedItemId_]
            if cfg and fpController_ then
                local camNode = fpController_:GetCameraNode()
                if camNode then
                    camNode.position = Vector3(cfg.pos.x, cfg.pos.y + 1.6, cfg.pos.z - 2)
                    UI.Toast.Show("已传送", { variant = "success", duration = 1.5 })
                end
            end
        end,
    }

    return UI.Panel {
        children = {
            itemInfoBox,
            UI.Label { text = "位置", fontSize = 11, fontWeight = "bold", fontColor = { 140, 180, 220, 255 }, marginBottom = 4 },
            UI.Panel { flexDirection = "row", gap = 4, marginBottom = 4, children = {
                UI.Label { text = "X", fontSize = 11, fontColor = { 160, 160, 170, 255 }, width = 16 },
                itemPosXField_,
                UI.Label { text = "Y", fontSize = 11, fontColor = { 160, 160, 170, 255 }, width = 16 },
                itemPosYField_,
                UI.Label { text = "Z", fontSize = 11, fontColor = { 160, 160, 170, 255 }, width = 16 },
                itemPosZField_,
            }},
            UI.Label { text = "缩放", fontSize = 11, fontWeight = "bold", fontColor = { 140, 180, 220, 255 }, marginTop = 6, marginBottom = 4 },
            UI.Panel { flexDirection = "row", gap = 4, marginBottom = 4, children = {
                UI.Label { text = "X", fontSize = 11, fontColor = { 160, 160, 170, 255 }, width = 16 },
                itemScaleXField_,
                UI.Label { text = "Y", fontSize = 11, fontColor = { 160, 160, 170, 255 }, width = 16 },
                itemScaleYField_,
                UI.Label { text = "Z", fontSize = 11, fontColor = { 160, 160, 170, 255 }, width = 16 },
                itemScaleZField_,
            }},
            UI.Label { text = "模型", fontSize = 11, fontWeight = "bold", fontColor = { 140, 180, 220, 255 }, marginTop = 6, marginBottom = 4 },
            itemModelDropdown_,
            UI.Label { text = "颜色", fontSize = 11, fontWeight = "bold", fontColor = { 140, 180, 220, 255 }, marginTop = 6, marginBottom = 4 },
            itemColorPicker_,
            UI.Panel { flexDirection = "row", alignItems = "center", gap = 8, marginTop = 6, children = {
                UI.Label { text = "自发光", fontSize = 11, fontColor = { 160, 160, 170, 255 } },
                itemEmissiveToggle_,
            }},
            itemBobLabel_,
            itemBobSlider_,
            teleportBtn,
        },
    }
end

-- ─── 任务物品（只读展示）──────────────────────────────────────────────────────

local function buildQuestItemsContent()
    local children = {}
    for _, itemId in ipairs(QUEST_ONLY_ITEMS) do
        local info = QuestData.GetItemInfo(itemId)
        if info then
            -- 查找赠送来源
            local sourceNPC = "未知"
            for npcId, stages in pairs(QuestData.Dialogues) do
                for _, lines in pairs(stages) do
                    for _, line in ipairs(lines) do
                        if line.giveItem == itemId then
                            local cfgs = NPCManager.GetConfigs()
                            sourceNPC = cfgs[npcId] and cfgs[npcId].name or npcId
                        end
                    end
                end
            end

            table.insert(children, UI.Panel {
                backgroundColor = { 35, 30, 45, 200 },
                borderRadius = 5,
                padding = 8,
                marginBottom = 6,
                children = {
                    UI.Panel { flexDirection = "row", alignItems = "center", gap = 6, marginBottom = 2, children = {
                        UI.Label { text = info.name, fontSize = 12, fontWeight = "bold", fontColor = { 230, 200, 140, 255 } },
                        UI.Label { text = "(" .. sourceNPC .. " 赠送)", fontSize = 10, fontColor = { 140, 170, 200, 180 } },
                    }},
                    UI.Label { text = info.desc, fontSize = 10, fontColor = { 170, 170, 185, 200 }, marginBottom = 2 },
                    UI.Label { text = info.hint, fontSize = 10, fontColor = { 140, 200, 160, 180 } },
                },
            })
        end
    end

    return UI.Panel { children = children }
end

function EditorDataTab.CreateItemPanel()
    local listContent = buildItemListContent()
    local propsContent = buildItemPropsContent()
    local questContent = buildQuestItemsContent()

    itemAccordion_ = UI.Accordion {
        items = {
            { id = "list",  title = "场景物品",  content = listContent,  defaultExpanded = true },
            { id = "props", title = "物品属性",  content = propsContent, defaultExpanded = false },
            { id = "quest", title = "任务物品 (对话获得)", content = questContent, defaultExpanded = false },
        },
        allowMultiple = true,
        variant = "outlined",
        animationDuration = 0.15,
    }

    return UI.Panel {
        flexGrow = 1,
        flexBasis = 0,
        children = {
            UI.ScrollView {
                flexGrow = 1,
                flexBasis = 0,
                padding = 8,
                children = { itemAccordion_ },
            },
        },
    }
end

-- ============================================================================
-- ===  设置 Tab  ==============================================================
-- ============================================================================

-- UI 引用
local speedSlider_ = nil
local speedLabel_ = nil
local sprintSlider_ = nil
local sprintLabel_ = nil
local sensitivitySlider_ = nil
local sensitivityLabel_ = nil
local eyeHeightSlider_ = nil
local eyeHeightLabel_ = nil
local interactSlider_ = nil
local interactLabel_ = nil
local fovSlider_ = nil
local fovLabel_ = nil
local gravitySlider_ = nil
local gravityLabel_ = nil

local function applySettings()
    local speed = speedSlider_:GetValue()          -- cm/s 整数
    GameConfig.Player.MoveSpeed = speed
    speedLabel_:SetText(string.format("%d", speed))

    local sprint = sprintSlider_:GetValue() / 10
    GameConfig.Player.SprintMultiplier = sprint
    sprintLabel_:SetText(string.format("%.1f", sprint))

    local sens = sensitivitySlider_:GetValue() / 100
    GameConfig.Player.MouseSensitivity = sens
    sensitivityLabel_:SetText(string.format("%.2f", sens))

    local eyeH = eyeHeightSlider_:GetValue() / 10
    GameConfig.Player.EyeHeight = eyeH
    eyeHeightLabel_:SetText(string.format("%.1f", eyeH))

    local interact = interactSlider_:GetValue() / 10
    GameConfig.Player.InteractDistance = interact
    interactLabel_:SetText(string.format("%.1f", interact))

    local fov = fovSlider_:GetValue()
    GameConfig.Camera.FOV = fov
    fovLabel_:SetText(tostring(math.floor(fov)))

    local grav = -gravitySlider_:GetValue() / 10
    GameConfig.Player.Gravity = grav
    gravityLabel_:SetText(string.format("%.1f", grav))

    -- 更新相机 FOV
    if fpController_ then
        local camNode = fpController_:GetCameraNode()
        if camNode then
            local cam = camNode:GetComponent("Camera")
            if cam then cam.fov = fov end
        end
    end

    settingsOverrides_ = {
        moveSpeed = speed,
        sprintMultiplier = sprint,
        mouseSensitivity = sens,
        eyeHeight = eyeH,
        interactDistance = interact,
        fov = fov,
        gravity = grav,
    }
end

local function refreshSettingsUI()
    if not speedSlider_ then return end

    speedSlider_:SetValue(math.floor(GameConfig.Player.MoveSpeed + 0.5))
    speedLabel_:SetText(string.format("%d", math.floor(GameConfig.Player.MoveSpeed + 0.5)))

    sprintSlider_:SetValue(math.floor(GameConfig.Player.SprintMultiplier * 10 + 0.5))
    sprintLabel_:SetText(string.format("%.1f", GameConfig.Player.SprintMultiplier))

    sensitivitySlider_:SetValue(math.floor(GameConfig.Player.MouseSensitivity * 100 + 0.5))
    sensitivityLabel_:SetText(string.format("%.2f", GameConfig.Player.MouseSensitivity))

    eyeHeightSlider_:SetValue(math.floor(GameConfig.Player.EyeHeight * 10 + 0.5))
    eyeHeightLabel_:SetText(string.format("%.1f", GameConfig.Player.EyeHeight))

    interactSlider_:SetValue(math.floor(GameConfig.Player.InteractDistance * 10 + 0.5))
    interactLabel_:SetText(string.format("%.1f", GameConfig.Player.InteractDistance))

    fovSlider_:SetValue(math.floor(GameConfig.Camera.FOV + 0.5))
    fovLabel_:SetText(tostring(math.floor(GameConfig.Camera.FOV)))

    gravitySlider_:SetValue(math.floor(-GameConfig.Player.Gravity * 10 + 0.5))
    gravityLabel_:SetText(string.format("%.1f", GameConfig.Player.Gravity))
end

local function makeSettingsRow(labelText, minVal, maxVal, defaultVal, onCreateSlider, onCreateLabel)
    local lbl = UI.Label {
        text = tostring(defaultVal),
        fontSize = 11,
        fontColor = { 180, 220, 255, 255 },
        width = 40,
        textAlign = "right",
    }
    local slider = UI.Slider {
        min = minVal,
        max = maxVal,
        value = defaultVal,
        width = "100%",
        flexShrink = 1,
        onChange = function(self, v)
            applySettings()
        end,
    }
    onCreateSlider(slider)
    onCreateLabel(lbl)

    return UI.Panel {
        flexDirection = "row",
        alignItems = "center",
        gap = 6,
        marginBottom = 4,
        children = {
            UI.Label {
                text = labelText,
                fontSize = 11,
                fontColor = { 170, 170, 180, 255 },
                width = 70,
            },
            slider,
            lbl,
        },
    }
end

local function buildPlayerContent()
    local speedRow = makeSettingsRow("速度cm/s", 100, 1500,
        math.floor(GameConfig.Player.MoveSpeed + 0.5),
        function(s) speedSlider_ = s end,
        function(l) speedLabel_ = l end)

    local sprintRow = makeSettingsRow("冲刺倍率", 10, 30,
        math.floor(GameConfig.Player.SprintMultiplier * 10 + 0.5),
        function(s) sprintSlider_ = s end,
        function(l) sprintLabel_ = l end)

    local sensRow = makeSettingsRow("鼠标灵敏", 1, 50,
        math.floor(GameConfig.Player.MouseSensitivity * 100 + 0.5),
        function(s) sensitivitySlider_ = s end,
        function(l) sensitivityLabel_ = l end)

    local eyeRow = makeSettingsRow("视点高度", 5, 30,
        math.floor(GameConfig.Player.EyeHeight * 10 + 0.5),
        function(s) eyeHeightSlider_ = s end,
        function(l) eyeHeightLabel_ = l end)

    local interactRow = makeSettingsRow("交互距离", 10, 100,
        math.floor(GameConfig.Player.InteractDistance * 10 + 0.5),
        function(s) interactSlider_ = s end,
        function(l) interactLabel_ = l end)

    return UI.Panel {
        children = { speedRow, sprintRow, sensRow, eyeRow, interactRow },
    }
end

local function buildCameraContent()
    local fovRow = makeSettingsRow("视野(FOV)", 40, 120,
        math.floor(GameConfig.Camera.FOV + 0.5),
        function(s) fovSlider_ = s end,
        function(l) fovLabel_ = l end)

    return UI.Panel {
        children = { fovRow },
    }
end

local function buildPhysicsContent()
    local gravRow = makeSettingsRow("重力强度", 10, 300,
        math.floor(-GameConfig.Player.Gravity * 10 + 0.5),
        function(s) gravitySlider_ = s end,
        function(l) gravityLabel_ = l end)

    local resetBtn = UI.Button {
        text = "恢复默认设置",
        fontSize = 11,
        variant = "secondary",
        marginTop = 8,
        onClick = function(self)
            UI.Modal.Confirm({
                title = "恢复默认",
                message = "确定将所有设置恢复为默认值？",
                onConfirm = function()
                    GameConfig.Player.MoveSpeed = 500
                    GameConfig.Player.SprintMultiplier = 1.6
                    GameConfig.Player.MouseSensitivity = 0.15
                    GameConfig.Player.EyeHeight = 1.6
                    GameConfig.Player.InteractDistance = 3.0
                    GameConfig.Camera.FOV = 70.0
                    GameConfig.Player.Gravity = -9.81
                    refreshSettingsUI()
                    applySettings()
                    UI.Toast.Show("已恢复默认", { variant = "success", duration = 1.5 })
                end,
            })
        end,
    }

    return UI.Panel {
        children = { gravRow, resetBtn },
    }
end

-- ─── 音频设置 ──────────────────────────────────────────────────────────────

local masterVolSlider_ = nil
local masterVolLabel_ = nil
local musicVolSlider_ = nil
local musicVolLabel_ = nil
local sfxVolSlider_ = nil
local sfxVolLabel_ = nil

local function applyAudioSettings()
    local masterVol = (masterVolSlider_:GetValue() or 100) / 100
    local musicVol = (musicVolSlider_:GetValue() or 40) / 100
    local sfxVol = (sfxVolSlider_:GetValue() or 70) / 100

    audio:SetMasterGain("Master", masterVol)
    audio:SetMasterGain("Music", musicVol)
    audio:SetMasterGain("Effect", sfxVol)

    settingsOverrides_.masterVolume = masterVol
    settingsOverrides_.musicVolume = musicVol
    settingsOverrides_.sfxVolume = sfxVol
end

local function refreshAudioUI()
    if not masterVolSlider_ then return end
    local masterVol = math.floor(audio:GetMasterGain("Master") * 100 + 0.5)
    local musicVol = math.floor(audio:GetMasterGain("Music") * 100 + 0.5)
    local sfxVol = math.floor(audio:GetMasterGain("Effect") * 100 + 0.5)

    masterVolSlider_:SetValue(masterVol)
    masterVolLabel_:SetText(masterVol .. "%")
    musicVolSlider_:SetValue(musicVol)
    musicVolLabel_:SetText(musicVol .. "%")
    sfxVolSlider_:SetValue(sfxVol)
    sfxVolLabel_:SetText(sfxVol .. "%")
end

local function buildAudioContent()
    masterVolLabel_ = UI.Label { text = "100%", fontSize = 11, fontColor = { 180, 220, 255, 255 }, width = 40, textAlign = "right" }
    masterVolSlider_ = UI.Slider {
        min = 0, max = 100, value = 100,
        onChange = function(self, val)
            masterVolLabel_:SetText(val .. "%")
            applyAudioSettings()
        end,
    }

    musicVolLabel_ = UI.Label { text = "40%", fontSize = 11, fontColor = { 180, 220, 255, 255 }, width = 40, textAlign = "right" }
    musicVolSlider_ = UI.Slider {
        min = 0, max = 100, value = 40,
        onChange = function(self, val)
            musicVolLabel_:SetText(val .. "%")
            applyAudioSettings()
        end,
    }

    sfxVolLabel_ = UI.Label { text = "70%", fontSize = 11, fontColor = { 180, 220, 255, 255 }, width = 40, textAlign = "right" }
    sfxVolSlider_ = UI.Slider {
        min = 0, max = 100, value = 70,
        onChange = function(self, val)
            sfxVolLabel_:SetText(val .. "%")
            applyAudioSettings()
        end,
    }

    local function audioRow(label, slider, valueLbl)
        return UI.Panel {
            flexDirection = "row", alignItems = "center", gap = 6, marginBottom = 4,
            children = {
                UI.Label { text = label, fontSize = 11, fontColor = { 170, 170, 180, 255 }, width = 70 },
                slider,
                valueLbl,
            },
        }
    end

    return UI.Panel {
        children = {
            audioRow("主音量", masterVolSlider_, masterVolLabel_),
            audioRow("音乐", musicVolSlider_, musicVolLabel_),
            audioRow("音效", sfxVolSlider_, sfxVolLabel_),
        },
    }
end

-- ─── 渲染设置 ──────────────────────────────────────────────────────────────

local renderDistSlider_ = nil
local renderDistLabel_ = nil
local shadowQualityDropdown_ = nil

local function applyRenderSettings()
    local dist = renderDistSlider_ and renderDistSlider_:GetValue() or 200
    local zone = scene_ and scene_:GetChild("EditorZone")
    if zone then
        local z = zone:GetComponent("Zone")
        if z then
            z:SetBoundingBox(BoundingBox(Vector3(-dist, -dist, -dist), Vector3(dist, dist, dist)))
        end
    end

    local quality = shadowQualityDropdown_ and shadowQualityDropdown_:GetValue() or 2048
    renderer.shadowMapSize = quality

    settingsOverrides_.renderDistance = dist
    settingsOverrides_.shadowMapSize = quality
end

local function buildRenderContent()
    renderDistLabel_ = UI.Label { text = "200m", fontSize = 11, fontColor = { 180, 220, 255, 255 }, width = 40, textAlign = "right" }
    renderDistSlider_ = UI.Slider {
        min = 50, max = 500, value = 200, step = 10,
        onChange = function(self, val)
            renderDistLabel_:SetText(val .. "m")
        end,
        onChangeEnd = function(self, val)
            renderDistLabel_:SetText(val .. "m")
            applyRenderSettings()
        end,
    }

    shadowQualityDropdown_ = UI.Dropdown {
        options = {
            { value = 512,  label = "低 (512)" },
            { value = 1024, label = "中 (1024)" },
            { value = 2048, label = "高 (2048)" },
            { value = 4096, label = "极高 (4096)" },
        },
        value = 2048,
        fontSize = 11,
        onChange = function(self, val) applyRenderSettings() end,
    }

    return UI.Panel {
        children = {
            UI.Panel {
                flexDirection = "row", alignItems = "center", gap = 6, marginBottom = 6,
                children = {
                    UI.Label { text = "渲染距离", fontSize = 11, fontColor = { 170, 170, 180, 255 }, width = 70 },
                    renderDistSlider_,
                    renderDistLabel_,
                },
            },
            UI.Panel {
                flexDirection = "row", alignItems = "center", gap = 6,
                children = {
                    UI.Label { text = "阴影质量", fontSize = 11, fontColor = { 170, 170, 180, 255 }, width = 70 },
                    shadowQualityDropdown_,
                },
            },
        },
    }
end

-- ─── 配色方案展示 ──────────────────────────────────────────────────────────

local function buildColorPaletteContent()
    -- 按分组组织颜色
    local groups = {
        { name = "自然", colors = { "Grass", "DirtPath", "Water", "TreeTrunk", "TreeLeaves", "DarkLeaves", "Rock" } },
        { name = "建筑", colors = { "WallWhite", "WallYellow", "WallOrange", "WallPink", "RoofRed", "RoofBrown", "RoofGray", "WoodDoor", "WoodFence" } },
        { name = "特殊", colors = { "Bridge", "Lantern", "Stone", "Temple", "SkyBlue" } },
    }

    -- 颜色中文名
    local colorNames = {
        Grass = "草地绿", DirtPath = "土路棕", Water = "河水蓝", TreeTrunk = "树干棕",
        TreeLeaves = "树叶绿", DarkLeaves = "深叶绿", Rock = "岩石灰",
        WallWhite = "白墙", WallYellow = "黄墙", WallOrange = "橙墙", WallPink = "粉墙",
        RoofRed = "红瓦", RoofBrown = "棕瓦", RoofGray = "灰瓦", WoodDoor = "木门", WoodFence = "篱笆",
        Bridge = "桥梁", Lantern = "灯笼红", Stone = "石板", Temple = "庙宇金", SkyBlue = "天空蓝",
    }

    local children = {}
    for _, group in ipairs(groups) do
        -- 分组标题
        table.insert(children, UI.Label {
            text = group.name,
            fontSize = 11, fontWeight = "bold",
            fontColor = { 140, 180, 220, 255 },
            marginTop = (#children > 0) and 6 or 0,
            marginBottom = 4,
        })

        -- 颜色色块行（使用 flexWrap）
        local swatches = {}
        for _, key in ipairs(group.colors) do
            local c = GameConfig.Colors[key]
            if c then
                table.insert(swatches, UI.Panel {
                    width = 48, marginBottom = 4,
                    alignItems = "center",
                    children = {
                        UI.Panel {
                            width = 28, height = 28,
                            borderRadius = 4,
                            backgroundColor = { math.floor(c.r * 255), math.floor(c.g * 255), math.floor(c.b * 255), 255 },
                            marginBottom = 2,
                        },
                        UI.Label {
                            text = colorNames[key] or key,
                            fontSize = 8,
                            fontColor = { 150, 150, 165, 200 },
                            textAlign = "center",
                        },
                    },
                })
            end
        end

        table.insert(children, UI.Panel {
            flexDirection = "row",
            flexWrap = "wrap",
            gap = 4,
            children = swatches,
        })
    end

    return UI.Panel { children = children }
end

-- ─── 游戏信息 ──────────────────────────────────────────────────────────────

local function buildGameInfoContent()
    -- 统计数据
    local npcConfigs = NPCManager.GetConfigs()
    local npcCount = 0
    for _ in pairs(npcConfigs) do npcCount = npcCount + 1 end

    local itemConfigs = ItemSpawner.GetConfigs()
    local spawnItemCount = 0
    for _ in pairs(itemConfigs) do spawnItemCount = spawnItemCount + 1 end

    local totalItemCount = 0
    for _ in pairs(QuestData.ItemInfo) do totalItemCount = totalItemCount + 1 end

    local stateCount = 0
    for _ in pairs(GameConfig.States) do stateCount = stateCount + 1 end

    local colorCount = 0
    for _ in pairs(GameConfig.Colors) do colorCount = colorCount + 1 end

    local function infoRow(label, value)
        return UI.Panel {
            flexDirection = "row", justifyContent = "space-between",
            marginBottom = 3,
            children = {
                UI.Label { text = label, fontSize = 11, fontColor = { 160, 160, 175, 200 } },
                UI.Label { text = value, fontSize = 11, fontWeight = "bold", fontColor = { 200, 200, 215, 255 } },
            },
        }
    end

    return UI.Panel {
        children = {
            infoRow("游戏名称", GameConfig.Title),
            infoRow("版本", GameConfig.Version),
            UI.Panel { height = 1, backgroundColor = { 50, 50, 65, 150 }, marginVertical = 6 },
            infoRow("NPC 数量", tostring(npcCount)),
            infoRow("场景物品", tostring(spawnItemCount)),
            infoRow("全部物品", tostring(totalItemCount)),
            infoRow("配色数量", tostring(colorCount)),
            infoRow("游戏状态", tostring(stateCount) .. " 种"),
        },
    }
end

function EditorDataTab.CreateSettingsPanel()
    local playerContent = buildPlayerContent()
    local cameraContent = buildCameraContent()
    local physicsContent = buildPhysicsContent()
    local audioContent = buildAudioContent()
    local renderContent = buildRenderContent()
    local paletteContent = buildColorPaletteContent()
    local gameInfoContent = buildGameInfoContent()

    local settingsAccordion = UI.Accordion {
        items = {
            { id = "info",    title = "游戏信息",  content = gameInfoContent, defaultExpanded = true },
            { id = "palette", title = "配色方案 (" .. (function() local n=0; for _ in pairs(GameConfig.Colors) do n=n+1 end; return n end)() .. " 色)", content = paletteContent, defaultExpanded = false },
            { id = "player",  title = "玩家控制",  content = playerContent,  defaultExpanded = true },
            { id = "camera",  title = "相机设置",  content = cameraContent,  defaultExpanded = true },
            { id = "physics", title = "物理",      content = physicsContent, defaultExpanded = true },
            { id = "audio",   title = "音频设置",  content = audioContent,   defaultExpanded = true },
            { id = "render",  title = "渲染设置",  content = renderContent,  defaultExpanded = false },
        },
        allowMultiple = true,
        variant = "outlined",
        animationDuration = 0.15,
    }

    return UI.Panel {
        flexGrow = 1,
        flexBasis = 0,
        children = {
            UI.ScrollView {
                flexGrow = 1,
                flexBasis = 0,
                padding = 8,
                children = { settingsAccordion },
            },
        },
    }
end

-- ============================================================================
-- 公开接口
-- ============================================================================

function EditorDataTab.Init(scene, controller)
    scene_ = scene
    fpController_ = controller
end

function EditorDataTab.Refresh()
    refreshNPCList()
    refreshItemList()
end

function EditorDataTab.Update(dt) end

-- 获取覆盖数据
function EditorDataTab.GetNPCOverrides()      return npcOverrides_ end
function EditorDataTab.GetDialogueOverrides() return dialogueOverrides_ end
function EditorDataTab.GetItemOverrides()     return itemOverrides_ end
function EditorDataTab.GetSettingsOverrides() return settingsOverrides_ end

-- 应用覆盖数据
function EditorDataTab.ApplyNPCOverrides(overrides)
    if not overrides then return end
    local GameEditor = require("editor.GameEditor")

    for npcId, data in pairs(overrides) do
        if data.pos then
            NPCManager.UpdateNPCTransform(npcId, Vector3(data.pos[1], data.pos[2], data.pos[3]))
        end

        if data.scale then
            local configs = NPCManager.GetConfigs()
            local cfg = configs[npcId]
            if cfg then cfg.scale = data.scale end
            local node = NPCManager.GetNode(npcId)
            if node then
                local s = data.scale
                local bodyNode = node:GetChild("Body")
                if bodyNode then bodyNode.scale = Vector3(0.5 * s, 1.4 * s, 0.35 * s) end
                local headNode = node:GetChild("Head")
                if headNode then headNode.scale = Vector3(0.35 * s, 0.35 * s, 0.35 * s) end
                local hairNode = node:GetChild("Hair")
                if hairNode then hairNode.scale = Vector3(0.38 * s, 0.22 * s, 0.38 * s) end
            end
        end

        local node = NPCManager.GetNode(npcId)
        if node then
            if data.bodyColor then
                local bodyNode = node:GetChild("Body")
                if bodyNode then
                    local m = bodyNode:GetComponent("StaticModel")
                    if m then
                        m:SetMaterial(GameConfig.CreateMaterial(Color(data.bodyColor[1], data.bodyColor[2], data.bodyColor[3], data.bodyColor[4] or 1.0)))
                    end
                end
            end
            if data.headColor then
                local headNode = node:GetChild("Head")
                if headNode then
                    local m = headNode:GetComponent("StaticModel")
                    if m then
                        m:SetMaterial(GameConfig.CreateMaterial(Color(data.headColor[1], data.headColor[2], data.headColor[3], data.headColor[4] or 1.0)))
                    end
                end
            end
            if data.hairColor then
                local hairNode = node:GetChild("Hair")
                if hairNode then
                    local m = hairNode:GetComponent("StaticModel")
                    if m then
                        m:SetMaterial(GameConfig.CreateMaterial(Color(data.hairColor[1], data.hairColor[2], data.hairColor[3], data.hairColor[4] or 1.0)))
                    end
                end
            end
        end

        npcOverrides_[npcId] = data
    end
end

function EditorDataTab.ApplyDialogueOverrides(overrides)
    if not overrides then return end
    for npcId, stageData in pairs(overrides) do
        if not QuestData.Dialogues[npcId] then
            QuestData.Dialogues[npcId] = {}
        end
        for stageStr, lines in pairs(stageData) do
            local stage = tonumber(stageStr) or 0
            QuestData.Dialogues[npcId][stage] = lines
        end
        dialogueOverrides_[npcId] = stageData
    end
end

function EditorDataTab.ApplyItemOverrides(overrides)
    if not overrides then return end
    local GameEditor = require("editor.GameEditor")

    for itemId, data in pairs(overrides) do
        if data.pos then
            ItemSpawner.UpdateItemTransform(itemId, Vector3(data.pos[1], data.pos[2], data.pos[3]))
        end

        local configs = ItemSpawner.GetConfigs()
        local cfg = configs[itemId]
        if cfg then
            if data.model then cfg.model = data.model end
            if data.color then
                cfg.color = Color(data.color[1], data.color[2], data.color[3], data.color[4] or 1.0)
            end
            if data.emissive ~= nil then cfg.emissive = data.emissive end
            if data.bobHeight then cfg.bobHeight = data.bobHeight end
            if data.scale then
                cfg.scale = Vector3(data.scale[1], data.scale[2], data.scale[3])
            end

            local node = ItemSpawner.GetNode(itemId)
            if node then
                local inner = node:GetChild("Inner")
                if inner then
                    if data.scale then
                        inner.scale = Vector3(data.scale[1], data.scale[2], data.scale[3])
                    end
                    local model = inner:GetComponent("StaticModel")
                    if model then
                        if data.model then
                            model:SetModel(cache:GetResource("Model", data.model))
                        end
                        if cfg.emissive then
                            model:SetMaterial(GameConfig.CreateEmissiveMaterial(cfg.color, 1.5))
                        else
                            model:SetMaterial(GameConfig.CreateMaterial(cfg.color))
                        end
                    end
                end
            end
        end

        itemOverrides_[itemId] = data
    end
end

function EditorDataTab.ApplySettingsOverrides(overrides)
    if not overrides then return end
    if overrides.moveSpeed then GameConfig.Player.MoveSpeed = overrides.moveSpeed end
    if overrides.sprintMultiplier then GameConfig.Player.SprintMultiplier = overrides.sprintMultiplier end
    if overrides.mouseSensitivity then GameConfig.Player.MouseSensitivity = overrides.mouseSensitivity end
    if overrides.eyeHeight then GameConfig.Player.EyeHeight = overrides.eyeHeight end
    if overrides.interactDistance then GameConfig.Player.InteractDistance = overrides.interactDistance end
    if overrides.fov then
        GameConfig.Camera.FOV = overrides.fov
        if fpController_ then
            local camNode = fpController_:GetCameraNode()
            if camNode then
                local cam = camNode:GetComponent("Camera")
                if cam then cam.fov = overrides.fov end
            end
        end
    end
    if overrides.gravity then GameConfig.Player.Gravity = overrides.gravity end
    -- 音频设置
    if overrides.masterVolume then audio:SetMasterGain("Master", overrides.masterVolume) end
    if overrides.musicVolume then audio:SetMasterGain("Music", overrides.musicVolume) end
    if overrides.sfxVolume then audio:SetMasterGain("Effect", overrides.sfxVolume) end
    -- 渲染设置
    if overrides.shadowMapSize then renderer.shadowMapSize = overrides.shadowMapSize end
    if overrides.renderDistance then
        local zone = scene_ and scene_:GetChild("EditorZone")
        if zone then
            local z = zone:GetComponent("Zone")
            if z then
                local d = overrides.renderDistance
                z:SetBoundingBox(BoundingBox(Vector3(-d, -d, -d), Vector3(d, d, d)))
            end
        end
    end
    settingsOverrides_ = overrides
    refreshSettingsUI()
    refreshAudioUI()
end

function EditorDataTab.RefreshSettings()
    refreshSettingsUI()
    refreshAudioUI()
end

return EditorDataTab
