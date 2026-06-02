-- ============================================================================
-- EditorResourceTab.lua — 资源浏览器面板
-- 浏览、搜索和使用引擎中可用的模型、纹理、材质、音效资源
-- ============================================================================

local GameConfig = require("config.GameConfig")
local UI = require("urhox-libs/UI")
local UIHelper = require("ui.UIHelper")

local EditorResourceTab = {}

---@type Scene
local scene_ = nil
local fpController_ = nil

-- ============================================================================
-- 常量
-- ============================================================================

local CATEGORIES = {
    { id = "models",    label = "模型", icon = "📦", dir = "Models",    exts = { ".mdl" } },
    { id = "textures",  label = "纹理", icon = "🖼", dir = "Textures",  exts = { ".png", ".jpg", ".jpeg", ".dds" } },
    { id = "materials", label = "材质", icon = "🎨", dir = "Materials", exts = { ".xml" } },
    { id = "sounds",    label = "音效", icon = "🔊", dir = "Sounds",   exts = { ".ogg", ".wav" } },
}

local CARD_SIZE = 100
local GRID_GAP = 6
local GRID_COLS = 3

-- 颜色
local CAT_BTN_ACTIVE   = { 50, 65, 95, 255 }
local CAT_BTN_NORMAL   = { 38, 38, 48, 255 }
local CAT_BTN_HOVER    = { 45, 50, 65, 255 }
local CARD_NORMAL_BG   = { 38, 38, 50, 255 }
local CARD_SELECTED_BG = { 50, 70, 110, 255 }
local CARD_HOVER_BG    = { 45, 50, 68, 255 }

-- ============================================================================
-- 状态
-- ============================================================================

local activeCategory_ = "models"
local searchQuery_ = ""
local selectedResource_ = nil     -- { path = "Models/Box.mdl", name = "Box.mdl", category = "models" }
local resourceCache_ = {}         -- category -> { {path, name, dir}, ... }
local addCounter_ = 0

-- ============================================================================
-- UI 引用
-- ============================================================================

local catButtons_ = {}
local searchField_ = nil
local gridContainer_ = nil
local selectedLabel_ = nil
local actionPanel_ = nil
local cardWidgets_ = {}           -- 当前显示的卡片列表
local countLabel_ = nil
local soundNode_ = nil            -- 用于播放音效预览

-- ============================================================================
-- 资源扫描
-- ============================================================================

--- 扫描指定目录的资源文件
---@param category table CATEGORIES 中的一项
---@return table[] 资源列表
local function scanCategory(category)
    local results = {}
    for _, ext in ipairs(category.exts) do
        local pattern = "*" .. ext
        local ok, files = pcall(function()
            return fileSystem:ScanDir(category.dir .. "/", pattern, SCAN_FILES, true)
        end)
        if ok and files then
            for i = 1, #files do
                local filename = files[i]
                local fullPath = category.dir .. "/" .. filename
                table.insert(results, {
                    path = fullPath,
                    name = filename,
                    dir = category.dir,
                    category = category.id,
                })
            end
        end
    end
    -- 按名称排序
    table.sort(results, function(a, b) return a.name < b.name end)
    return results
end

--- 扫描所有分类的资源
local function scanAllResources()
    for _, cat in ipairs(CATEGORIES) do
        resourceCache_[cat.id] = scanCategory(cat)
    end
    print(string.format("[ResourceTab] 扫描完成: 模型 %d, 纹理 %d, 材质 %d, 音效 %d",
        #(resourceCache_.models or {}),
        #(resourceCache_.textures or {}),
        #(resourceCache_.materials or {}),
        #(resourceCache_.sounds or {})
    ))
end

--- 获取过滤后的资源列表
---@return table[]
local function getFilteredResources()
    local resources = resourceCache_[activeCategory_] or {}
    if searchQuery_ == "" then return resources end

    local query = string.lower(searchQuery_)
    local filtered = {}
    for _, res in ipairs(resources) do
        if string.find(string.lower(res.name), query, 1, true) then
            table.insert(filtered, res)
        end
    end
    return filtered
end

-- ============================================================================
-- 资源卡片创建
-- ============================================================================

--- 获取资源的显示图标 emoji
---@param res table
---@return string
local function getResourceIcon(res)
    if res.category == "models" then
        local n = string.lower(res.name)
        if string.find(n, "box") then return "📦"
        elseif string.find(n, "sphere") then return "🔮"
        elseif string.find(n, "cylinder") then return "🧱"
        elseif string.find(n, "cone") then return "🔺"
        elseif string.find(n, "plane") then return "📐"
        elseif string.find(n, "pyramid") then return "🔻"
        elseif string.find(n, "torus") then return "💍"
        else return "📦"
        end
    elseif res.category == "materials" then
        return "🎨"
    elseif res.category == "sounds" then
        return "🔊"
    end
    return "📄"
end

--- 获取不含扩展名的文件名
---@param filename string
---@return string
local function stripExtension(filename)
    -- 去掉路径中的子目录
    local name = string.match(filename, "([^/]+)$") or filename
    -- 去掉扩展名
    return string.match(name, "(.+)%..+$") or name
end

--- 创建一个资源卡片
---@param res table
---@return table widget
local function createResourceCard(res)
    local isSelected = (selectedResource_ and selectedResource_.path == res.path)
    local displayName = stripExtension(res.name)
    -- 截断长名字
    if #displayName > 12 then
        displayName = string.sub(displayName, 1, 11) .. ".."
    end

    local cardChildren = {}

    if res.category == "textures" then
        -- 纹理: 用 backgroundImage 显示真实预览
        table.insert(cardChildren, UI.Panel {
            width = CARD_SIZE - 16,
            height = CARD_SIZE - 32,
            backgroundImage = res.path,
            backgroundFit = "contain",
            borderRadius = 4,
            marginBottom = 2,
            alignSelf = "center",
        })
    else
        -- 模型/材质/音效: emoji 图标
        table.insert(cardChildren, UI.Label {
            text = getResourceIcon(res),
            fontSize = 28,
            textAlign = "center",
            marginBottom = 2,
        })
    end

    -- 文件名
    table.insert(cardChildren, UI.Label {
        text = displayName,
        fontSize = 9,
        fontColor = { 180, 180, 195, 255 },
        textAlign = "center",
        width = CARD_SIZE - 8,
    })

    local card = UI.Panel {
        width = CARD_SIZE,
        height = CARD_SIZE,
        backgroundColor = isSelected and CARD_SELECTED_BG or CARD_NORMAL_BG,
        hoverBackgroundColor = isSelected and CARD_SELECTED_BG or CARD_HOVER_BG,
        borderRadius = 6,
        borderWidth = isSelected and 1 or 0,
        borderColor = { 80, 120, 200, 200 },
        justifyContent = "center",
        alignItems = "center",
        paddingVertical = 4,
        paddingHorizontal = 4,
        cursor = "pointer",
        onClick = function(self)
            selectResource(res)
        end,
    }

    -- 手动添加子元素
    for _, child in ipairs(cardChildren) do
        card:AddChild(child)
    end

    return card
end

-- ============================================================================
-- 选中逻辑
-- ============================================================================

--- 选中一个资源
---@param res table|nil
function selectResource(res)
    selectedResource_ = res

    -- 更新选中标签
    if selectedLabel_ then
        if res then
            selectedLabel_:SetText("已选: " .. res.name)
        else
            selectedLabel_:SetText("未选择资源")
        end
    end

    -- 更新操作面板可见性
    updateActionPanel()

    -- 刷新网格高亮
    refreshGrid()
end

--- 更新操作按钮面板
function updateActionPanel()
    if not actionPanel_ then return end
    if selectedResource_ then
        actionPanel_:Show()
    else
        actionPanel_:Hide()
    end
end

-- ============================================================================
-- 网格刷新
-- ============================================================================

--- 刷新资源网格
function refreshGrid()
    if not gridContainer_ then return end

    -- 清空容器
    UIHelper.DestroyChildren(gridContainer_)
    cardWidgets_ = {}

    local resources = getFilteredResources()

    -- 更新计数
    if countLabel_ then
        countLabel_:SetText(tostring(#resources) .. " 项")
    end

    if #resources == 0 then
        local emptyLabel = UI.Label {
            text = searchQuery_ ~= "" and "无匹配结果" or "该分类暂无资源",
            fontSize = 12,
            fontColor = { 120, 120, 130, 180 },
            textAlign = "center",
            marginTop = 30,
            width = "100%",
        }
        gridContainer_:AddChild(emptyLabel)
        return
    end

    -- 创建网格
    local grid = UI.SimpleGrid {
        columns = GRID_COLS,
        gap = GRID_GAP,
        width = "100%",
        paddingHorizontal = 4,
        paddingVertical = 4,
    }

    for _, res in ipairs(resources) do
        local card = createResourceCard(res)
        grid:AddChild(card)
        table.insert(cardWidgets_, card)
    end

    gridContainer_:AddChild(grid)
end

-- ============================================================================
-- 分类切换
-- ============================================================================

--- 切换分类
---@param categoryId string
local function switchCategory(categoryId)
    if categoryId == activeCategory_ then return end
    activeCategory_ = categoryId

    -- 更新按钮高亮
    for _, cat in ipairs(CATEGORIES) do
        local btn = catButtons_[cat.id]
        if btn then
            if cat.id == categoryId then
                btn:SetStyle({ backgroundColor = CAT_BTN_ACTIVE })
            else
                btn:SetStyle({ backgroundColor = CAT_BTN_NORMAL })
            end
        end
    end

    -- 清除选中
    selectedResource_ = nil
    if selectedLabel_ then
        selectedLabel_:SetText("未选择资源")
    end
    updateActionPanel()

    refreshGrid()
end

-- ============================================================================
-- 操作功能
-- ============================================================================

--- 添加模型到场景
local function addModelToScene()
    if not selectedResource_ or selectedResource_.category ~= "models" then return end
    if not scene_ or not fpController_ then return end

    local village = scene_:GetChild("Village")
    if not village then
        village = scene_:CreateChild("Village")
    end

    addCounter_ = addCounter_ + 1
    local name = "ResObj_" .. addCounter_

    local camNode = fpController_:GetCameraNode()
    local camPos = camNode.position
    local camDir = camNode.rotation * Vector3.FORWARD
    local spawnPos = Vector3(camPos.x + camDir.x * 5, 0.5, camPos.z + camDir.z * 5)

    local node = village:CreateChild(name)
    node.position = spawnPos

    local model = node:CreateComponent("StaticModel")
    model:SetModel(cache:GetResource("Model", selectedResource_.path))
    model:SetMaterial(GameConfig.CreateMaterial(Color(0.6, 0.6, 0.6, 1.0)))
    model.castShadows = true

    UI.Toast.Show("已添加: " .. stripExtension(selectedResource_.name), { variant = "success", duration = 2 })
    print("[ResourceTab] 添加模型: " .. selectedResource_.path .. " -> " .. name)
end

--- 应用纹理到选中节点
local function applyTextureToSelected()
    if not selectedResource_ then return end
    if not scene_ then return end

    -- 通过 EditorSceneTab 获取当前选中的场景节点
    local EditorSceneTab = require("editor.EditorSceneTab")
    local selectedNode = EditorSceneTab.GetSelectedNode and EditorSceneTab.GetSelectedNode()
    if not selectedNode then
        UI.Toast.Show("请先在场景面板选中一个节点", { variant = "warning", duration = 2 })
        return
    end

    -- 查找 StaticModel
    local staticModel = selectedNode:GetComponent("StaticModel")
    if not staticModel then
        UI.Toast.Show("选中节点无模型组件", { variant = "warning", duration = 2 })
        return
    end

    if selectedResource_.category == "textures" then
        -- 创建新材质并设置纹理
        local mat = Material:new()
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRDiff.xml"))
        local tex = cache:GetResource("Texture2D", selectedResource_.path)
        if tex then
            mat:SetTexture(TU_DIFFUSE, tex)
            staticModel:SetMaterial(mat)
            UI.Toast.Show("纹理已应用: " .. stripExtension(selectedResource_.name), { variant = "success", duration = 2 })
        else
            UI.Toast.Show("纹理加载失败", { variant = "error", duration = 2 })
        end
    elseif selectedResource_.category == "materials" then
        -- 加载材质 XML
        local mat = cache:GetResource("Material", selectedResource_.path)
        if mat then
            staticModel:SetMaterial(mat)
            UI.Toast.Show("材质已应用: " .. stripExtension(selectedResource_.name), { variant = "success", duration = 2 })
        else
            UI.Toast.Show("材质加载失败", { variant = "error", duration = 2 })
        end
    elseif selectedResource_.category == "models" then
        -- 替换模型
        local mdl = cache:GetResource("Model", selectedResource_.path)
        if mdl then
            staticModel:SetModel(mdl)
            UI.Toast.Show("模型已替换: " .. stripExtension(selectedResource_.name), { variant = "success", duration = 2 })
        else
            UI.Toast.Show("模型加载失败", { variant = "error", duration = 2 })
        end
    end
end

--- 预览播放音效
local function previewSound()
    if not selectedResource_ or selectedResource_.category ~= "sounds" then return end
    if not scene_ then return end

    -- 创建或复用播放节点
    if not soundNode_ then
        soundNode_ = scene_:CreateChild("ResourceSoundPreview")
    end

    local sound = cache:GetResource("Sound", selectedResource_.path)
    if sound then
        local source = soundNode_:GetOrCreateComponent("SoundSource")
        source:Play(sound)
        UI.Toast.Show("播放: " .. stripExtension(selectedResource_.name), { variant = "info", duration = 1.5 })
    else
        UI.Toast.Show("音效加载失败", { variant = "error", duration = 2 })
    end
end

-- ============================================================================
-- UI 构建
-- ============================================================================

--- 构建分类按钮行
---@return table
local function buildCategoryBar()
    local children = {}
    catButtons_ = {}

    for _, cat in ipairs(CATEGORIES) do
        local isActive = (cat.id == activeCategory_)
        local btn = UI.Button {
            text = cat.icon .. " " .. cat.label,
            fontSize = 10,
            flexGrow = 1,
            paddingHorizontal = 2,
            paddingVertical = 5,
            backgroundColor = isActive and CAT_BTN_ACTIVE or CAT_BTN_NORMAL,
            hoverBackgroundColor = CAT_BTN_HOVER,
            textColor = isActive and { 220, 220, 235, 255 } or { 150, 150, 165, 255 },
            borderRadius = 4,
            onClick = function(self)
                switchCategory(cat.id)
            end,
        }
        catButtons_[cat.id] = btn
        table.insert(children, btn)
    end

    return UI.Panel {
        flexDirection = "row",
        gap = 3,
        paddingHorizontal = 6,
        paddingVertical = 6,
        backgroundColor = { 28, 28, 36, 255 },
        borderBottomWidth = 1,
        borderColor = { 45, 45, 55, 255 },
        children = children,
    }
end

--- 构建搜索栏
---@return table
local function buildSearchBar()
    countLabel_ = UI.Label {
        text = "0 项",
        fontSize = 10,
        fontColor = { 110, 110, 125, 200 },
        minWidth = 36,
        textAlign = "right",
    }

    searchField_ = UI.TextField {
        placeholder = "搜索资源...",
        fontSize = 11,
        flexGrow = 1,
        paddingVertical = 4,
        paddingHorizontal = 8,
        backgroundColor = { 35, 35, 48, 255 },
        borderRadius = 4,
        onSubmit = function(self, value)
            searchQuery_ = value or ""
            selectResource(nil)
            refreshGrid()
        end,
        onBlur = function(self, value)
            searchQuery_ = value or ""
            selectResource(nil)
            refreshGrid()
        end,
    }

    return UI.Panel {
        flexDirection = "row",
        alignItems = "center",
        gap = 6,
        paddingHorizontal = 6,
        paddingVertical = 4,
        borderBottomWidth = 1,
        borderColor = { 40, 40, 50, 255 },
        children = {
            UI.Label {
                text = "🔍",
                fontSize = 12,
            },
            searchField_,
            countLabel_,
        },
    }
end

--- 构建操作按钮面板
---@return table
local function buildActionPanel()
    selectedLabel_ = UI.Label {
        text = "未选择资源",
        fontSize = 10,
        fontColor = { 150, 150, 165, 220 },
        marginBottom = 4,
        width = "100%",
    }

    local addBtn = UI.Button {
        text = "添加到场景",
        fontSize = 11,
        variant = "primary",
        flexGrow = 1,
        paddingVertical = 5,
        onClick = function(self) addModelToScene() end,
    }

    local applyBtn = UI.Button {
        text = "应用到节点",
        fontSize = 11,
        variant = "secondary",
        flexGrow = 1,
        paddingVertical = 5,
        onClick = function(self) applyTextureToSelected() end,
    }

    local playBtn = UI.Button {
        text = "▶ 预览",
        fontSize = 11,
        flexGrow = 1,
        paddingVertical = 5,
        backgroundColor = { 45, 70, 55, 255 },
        hoverBackgroundColor = { 55, 85, 65, 255 },
        textColor = { 160, 220, 180, 255 },
        onClick = function(self) previewSound() end,
    }

    actionPanel_ = UI.Panel {
        paddingHorizontal = 6,
        paddingVertical = 6,
        borderTopWidth = 1,
        borderColor = { 45, 45, 55, 255 },
        backgroundColor = { 30, 30, 40, 255 },
        visible = false,
        children = {
            selectedLabel_,
            UI.Panel {
                flexDirection = "row",
                gap = 6,
                children = { addBtn, applyBtn, playBtn },
            },
        },
    }

    return actionPanel_
end

-- ============================================================================
-- 公开接口
-- ============================================================================

--- 初始化
---@param scene Scene
---@param controller table FirstPersonController 实例
function EditorResourceTab.Init(scene, controller)
    scene_ = scene
    fpController_ = controller
    scanAllResources()
    print("[ResourceTab] 资源浏览器初始化完成")
end

--- 创建面板 UI
---@return table UI.Panel
function EditorResourceTab.CreateResourcePanel()
    local categoryBar = buildCategoryBar()
    local searchBar = buildSearchBar()
    local action = buildActionPanel()

    -- 网格容器（放在 ScrollView 里）
    gridContainer_ = UI.Panel {
        width = "100%",
        paddingVertical = 4,
    }

    local scrollView = UI.ScrollView {
        flexGrow = 1,
        flexBasis = 0,
        scrollY = true,
        showScrollbar = true,
        children = { gridContainer_ },
    }

    -- 首次刷新
    refreshGrid()

    return UI.Panel {
        width = "100%",
        flexGrow = 1,
        flexBasis = 0,
        children = {
            categoryBar,
            searchBar,
            scrollView,
            action,
        },
    }
end

--- 刷新（重新扫描并刷新 UI）
function EditorResourceTab.Refresh()
    scanAllResources()
    refreshGrid()
end

--- 每帧更新
---@param dt number
function EditorResourceTab.Update(dt)
    -- 资源浏览器不需要每帧更新
end

--- 获取当前选中的资源
---@return table|nil
function EditorResourceTab.GetSelectedResource()
    return selectedResource_
end

return EditorResourceTab
