-- ============================================================================
-- EditorSceneTab.lua — 场景编辑 Tab（含变换 + 材质，Accordion 折叠分组）
-- ============================================================================

local GameConfig = require("config.GameConfig")
local UI = require("urhox-libs/UI")
local EditorHistory = require("editor.EditorHistory")
local UIHelper = require("ui.UIHelper")

local EditorSceneTab = {}

---@type Scene
local scene_ = nil
local fpController_ = nil

-- 当前选中节点
---@type Node
local selectedNode_ = nil
local selectedNodeName_ = ""

-- 覆盖记录
local sceneOverrides_ = {}
local materialOverrides_ = {}
local envOverrides_ = {}

-- 环境组件引用
---@type Zone
local zone_ = nil
---@type Light
local sunLight_ = nil
---@type Node
local sunNode_ = nil

-- ============================================================================
-- UI 引用
-- ============================================================================

-- 节点列表
local nodeListPanel_ = nil
local selectedLabel_ = nil

-- 变换
local posXField_ = nil
local posYField_ = nil
local posZField_ = nil
local scaleXField_ = nil
local scaleYField_ = nil
local scaleZField_ = nil
local rotXSlider_ = nil
local rotXLabel_ = nil
local rotYSlider_ = nil
local rotYLabel_ = nil
local rotZSlider_ = nil
local rotZLabel_ = nil
local shadowToggle_ = nil

-- 吸附
local snapEnabled_ = false
local snapStep_ = 1.0
local snapToggle_ = nil
local snapStepDropdown_ = nil

-- 节点搜索
local nodeSearchField_ = nil
local nodeSearchQuery_ = ""
local nodeCountLabel_ = nil

-- 材质
local colorPicker_ = nil
local roughnessSlider_ = nil
local roughnessLabel_ = nil
local metallicSlider_ = nil
local metallicLabel_ = nil
local emissiveToggle_ = nil
local emissiveIntensitySlider_ = nil
local emissiveIntensityLabel_ = nil

-- 新增物体
local addModelDropdown_ = nil
local addCounter_ = 0

-- 环境光照 UI
local ambientColorPicker_ = nil
local sunPitchSlider_ = nil
local sunPitchLabel_ = nil
local sunYawSlider_ = nil
local sunYawLabel_ = nil
local sunColorPicker_ = nil
local sunBrightnessSlider_ = nil
local sunBrightnessLabel_ = nil

-- 雾效 UI
local fogToggle_ = nil
local fogColorPicker_ = nil
local fogStartSlider_ = nil
local fogStartLabel_ = nil
local fogEndSlider_ = nil
local fogEndLabel_ = nil

-- Accordion 引用
local sceneAccordion_ = nil

--- 动态扫描 Models 目录生成下拉选项
local function scanModelOptions()
    local options = {}
    local ok, files = pcall(function()
        return fileSystem:ScanDir("Models/", "*.mdl", SCAN_FILES, true)
    end)
    if ok and files then
        for i = 1, #files do
            local name = files[i]
            local displayName = string.match(name, "(.+)%.mdl$") or name
            table.insert(options, { value = "Models/" .. name, label = displayName })
        end
    end
    -- 确保至少有基础模型
    if #options == 0 then
        options = {
            { value = "Models/Box.mdl",      label = "Box" },
            { value = "Models/Sphere.mdl",   label = "Sphere" },
            { value = "Models/Cylinder.mdl", label = "Cylinder" },
            { value = "Models/Cone.mdl",     label = "Cone" },
            { value = "Models/Pyramid.mdl",  label = "Pyramid" },
        }
    end
    table.sort(options, function(a, b) return a.label < b.label end)
    return options
end

local MODEL_OPTIONS = scanModelOptions()

-- ============================================================================
-- 辅助函数
-- ============================================================================

local function findStaticModel(node)
    local model = node:GetComponent("StaticModel")
    if model then return model end
    local children = node:GetChildren(false)
    for i = 1, #children do
        model = children[i]:GetComponent("StaticModel")
        if model then return model end
    end
    return nil
end

local function getSceneNodes()
    local village = scene_:GetChild("Village")
    if not village then return {} end
    local children = village:GetChildren(false)
    local nodes = {}
    for i = 1, #children do
        nodes[i] = children[i]
    end
    return nodes
end

-- ============================================================================
-- 环境组件初始化 / 查找
-- ============================================================================

local function findOrCreateZone()
    if zone_ then return zone_ end

    -- 先找已有的 Zone
    local zoneNode = scene_:GetChild("EditorZone")
    if zoneNode then
        zone_ = zoneNode:GetComponent("Zone")
        if zone_ then return zone_ end
    end

    -- 创建新 Zone
    zoneNode = scene_:CreateChild("EditorZone")
    zone_ = zoneNode:CreateComponent("Zone")
    zone_:SetBoundingBox(BoundingBox(Vector3(-200, -200, -200), Vector3(200, 200, 200)))
    zone_.ambientColor = Color(0.4, 0.4, 0.45, 1.0)
    zone_.fogColor = Color(0.7, 0.75, 0.8, 1.0)
    zone_.fogStart = 60.0
    zone_.fogEnd = 200.0
    print("[EditorSceneTab] 创建 Zone 组件")
    return zone_
end

local function findSunLight()
    if sunLight_ then return sunLight_, sunNode_ end

    -- 从 LightGroup 查找
    local lightGroup = scene_:GetChild("LightGroup")
    if lightGroup then
        local children = lightGroup:GetChildren(true)
        for i = 1, #children do
            local light = children[i]:GetComponent("Light")
            if light and light.lightType == LIGHT_DIRECTIONAL then
                sunLight_ = light
                sunNode_ = children[i]
                return sunLight_, sunNode_
            end
        end
    end

    -- 查找直接子节点
    local directLight = scene_:GetChild("DirectionalLight")
    if directLight then
        sunLight_ = directLight:GetComponent("Light")
        sunNode_ = directLight
        if sunLight_ then return sunLight_, sunNode_ end
    end

    return nil, nil
end

-- ============================================================================
-- 环境光照 — 应用
-- ============================================================================

local function applyAmbientLight()
    local z = findOrCreateZone()
    if not z then return end

    local GameEditor = require("editor.GameEditor")
    local rgba = ambientColorPicker_:GetValue() or { 102, 102, 115, 255 }
    z.ambientColor = GameEditor.RGBAToColor(rgba)

    envOverrides_.ambientColor = rgba
end

local function applySunLight()
    local light, node = findSunLight()
    if not light or not node then return end

    local pitch = sunPitchSlider_ and sunPitchSlider_:GetValue() or 45
    local yaw = sunYawSlider_ and sunYawSlider_:GetValue() or 30
    node.rotation = Quaternion(pitch, yaw, 0)

    if sunColorPicker_ then
        local GameEditor = require("editor.GameEditor")
        local rgba = sunColorPicker_:GetValue() or { 255, 242, 217, 255 }
        light.color = GameEditor.RGBAToColor(rgba)
        envOverrides_.sunColor = rgba
    end

    if sunBrightnessSlider_ then
        local brightness = sunBrightnessSlider_:GetValue() / 100
        light.brightness = brightness
        envOverrides_.sunBrightness = sunBrightnessSlider_:GetValue()
    end

    envOverrides_.sunPitch = pitch
    envOverrides_.sunYaw = yaw
end

-- ============================================================================
-- 雾效 — 应用
-- ============================================================================

local function applyFog()
    local z = findOrCreateZone()
    if not z then return end

    local enabled = fogToggle_ and fogToggle_:GetValue() or false

    if enabled then
        local GameEditor = require("editor.GameEditor")
        local rgba = fogColorPicker_ and fogColorPicker_:GetValue() or { 179, 191, 204, 255 }
        z.fogColor = GameEditor.RGBAToColor(rgba)
        z.fogStart = fogStartSlider_ and fogStartSlider_:GetValue() or 60
        z.fogEnd = fogEndSlider_ and fogEndSlider_:GetValue() or 200
        envOverrides_.fogColor = rgba
    else
        -- 禁用：把雾推到很远
        z.fogStart = 9000
        z.fogEnd = 10000
    end

    envOverrides_.fogEnabled = enabled
    envOverrides_.fogStart = fogStartSlider_ and fogStartSlider_:GetValue() or 60
    envOverrides_.fogEnd = fogEndSlider_ and fogEndSlider_:GetValue() or 200
end

-- ============================================================================
-- 变换 — 刷新 / 应用
-- ============================================================================

local function refreshTransformUI()
    if not selectedNode_ then
        if selectedLabel_ then selectedLabel_:SetText("未选中") end
        return
    end

    if selectedLabel_ then
        selectedLabel_:SetText("选中: " .. selectedNodeName_)
    end

    local pos = selectedNode_.position
    local scl = selectedNode_.scale
    local euler = selectedNode_.rotation:EulerAngles()
    local rotX = euler.x
    local rotY = euler.y
    local rotZ = euler.z

    if posXField_ then posXField_:SetValue(string.format("%.2f", pos.x)) end
    if posYField_ then posYField_:SetValue(string.format("%.2f", pos.y)) end
    if posZField_ then posZField_:SetValue(string.format("%.2f", pos.z)) end
    if scaleXField_ then scaleXField_:SetValue(string.format("%.2f", scl.x)) end
    if scaleYField_ then scaleYField_:SetValue(string.format("%.2f", scl.y)) end
    if scaleZField_ then scaleZField_:SetValue(string.format("%.2f", scl.z)) end
    if rotXSlider_ then rotXSlider_:SetValue(math.floor(rotX + 0.5)) end
    if rotXLabel_ then rotXLabel_:SetText("X: " .. math.floor(rotX + 0.5) .. "°") end
    if rotYSlider_ then rotYSlider_:SetValue(math.floor(rotY + 0.5)) end
    if rotYLabel_ then rotYLabel_:SetText("Y: " .. math.floor(rotY + 0.5) .. "°") end
    if rotZSlider_ then rotZSlider_:SetValue(math.floor(rotZ + 0.5)) end
    if rotZLabel_ then rotZLabel_:SetText("Z: " .. math.floor(rotZ + 0.5) .. "°") end

    if shadowToggle_ then
        local model = findStaticModel(selectedNode_)
        if model then shadowToggle_:SetValue(model.castShadows) end
    end
end

--- 吸附对齐值
local function snapValue(val, step)
    if not snapEnabled_ or step <= 0 then return val end
    return math.floor(val / step + 0.5) * step
end

local function applyTransform()
    if not selectedNode_ then return end

    -- 记录旧状态用于撤销
    local oldPos = Vector3(selectedNode_.position)
    local oldRot = Quaternion(selectedNode_.rotation)
    local oldScale = Vector3(selectedNode_.scale)

    local px = tonumber(posXField_:GetValue()) or selectedNode_.position.x
    local py = tonumber(posYField_:GetValue()) or selectedNode_.position.y
    local pz = tonumber(posZField_:GetValue()) or selectedNode_.position.z
    px = snapValue(px, snapStep_)
    py = snapValue(py, snapStep_)
    pz = snapValue(pz, snapStep_)
    selectedNode_.position = Vector3(px, py, pz)

    local sx = tonumber(scaleXField_:GetValue()) or selectedNode_.scale.x
    local sy = tonumber(scaleYField_:GetValue()) or selectedNode_.scale.y
    local sz = tonumber(scaleZField_:GetValue()) or selectedNode_.scale.z
    selectedNode_.scale = Vector3(sx, sy, sz)

    local castShadow = shadowToggle_ and shadowToggle_:GetValue() or false
    local model = findStaticModel(selectedNode_)
    if model then model.castShadows = castShadow end

    local rx = rotXSlider_ and rotXSlider_:GetValue() or 0
    local ry = rotYSlider_ and rotYSlider_:GetValue() or 0
    local rz = rotZSlider_ and rotZSlider_:GetValue() or 0

    sceneOverrides_[selectedNodeName_] = {
        pos = { px, py, pz },
        scale = { sx, sy, sz },
        rotX = rx,
        rotY = ry,
        rotZ = rz,
        castShadows = castShadow,
    }

    -- 记录撤销
    local newPos = Vector3(selectedNode_.position)
    local newRot = Quaternion(selectedNode_.rotation)
    local newScale = Vector3(selectedNode_.scale)
    if oldPos ~= newPos or oldScale ~= newScale then
        EditorHistory.Record(EditorHistory.MakeTransformCmd(
            selectedNode_, oldPos, oldRot, oldScale, newPos, newRot, newScale, refreshTransformUI
        ))
    end
end

--- 应用三轴旋转（axis = "X"/"Y"/"Z"）
local function applyRotation(axis, val)
    if not selectedNode_ then return end

    local rx = rotXSlider_ and rotXSlider_:GetValue() or 0
    local ry = rotYSlider_ and rotYSlider_:GetValue() or 0
    local rz = rotZSlider_ and rotZSlider_:GetValue() or 0

    if axis == "X" then rx = val
    elseif axis == "Y" then ry = val
    elseif axis == "Z" then rz = val
    end

    selectedNode_.rotation = Quaternion(rx, ry, rz)

    if rotXLabel_ then rotXLabel_:SetText("X: " .. math.floor(rx + 0.5) .. "°") end
    if rotYLabel_ then rotYLabel_:SetText("Y: " .. math.floor(ry + 0.5) .. "°") end
    if rotZLabel_ then rotZLabel_:SetText("Z: " .. math.floor(rz + 0.5) .. "°") end

    if not sceneOverrides_[selectedNodeName_] then
        local pos = selectedNode_.position
        local scl = selectedNode_.scale
        local mdl = findStaticModel(selectedNode_)
        sceneOverrides_[selectedNodeName_] = {
            pos = { pos.x, pos.y, pos.z },
            scale = { scl.x, scl.y, scl.z },
            castShadows = mdl and mdl.castShadows or true,
        }
    end
    sceneOverrides_[selectedNodeName_].rotX = rx
    sceneOverrides_[selectedNodeName_].rotY = ry
    sceneOverrides_[selectedNodeName_].rotZ = rz
end

--- 贴地：将节点放到 Y=0 + 半高位置
local function alignToGround()
    if not selectedNode_ then
        UI.Toast.Show("请先选中节点", { variant = "warning", duration = 2 })
        return
    end

    local oldPos = Vector3(selectedNode_.position)
    local model = findStaticModel(selectedNode_)
    local halfH = 0.5
    if model then
        local size = model.boundingBox.size
        halfH = size.y * selectedNode_.scale.y * 0.5
    end
    selectedNode_.position = Vector3(selectedNode_.position.x, halfH, selectedNode_.position.z)

    -- 记录撤销
    local newPos = Vector3(selectedNode_.position)
    if oldPos ~= newPos then
        EditorHistory.Record(EditorHistory.MakeTransformCmd(
            selectedNode_, oldPos, selectedNode_.rotation, selectedNode_.scale,
            newPos, selectedNode_.rotation, selectedNode_.scale, refreshTransformUI
        ))
    end

    refreshTransformUI()
    applyTransform()
    UI.Toast.Show("已贴地对齐", { variant = "success", duration = 1.5 })
end

-- ============================================================================
-- 材质 — 刷新 / 应用
-- ============================================================================

local function refreshMaterialUI()
    if not selectedNode_ or not colorPicker_ then return end

    local model = findStaticModel(selectedNode_)
    if model and model:GetMaterial(0) then
        local mat = model:GetMaterial(0)

        local diffColor = mat:GetShaderParameter("MatDiffColor")
        if diffColor then
            local GameEditor = require("editor.GameEditor")
            local c = diffColor:GetColor()
            colorPicker_:SetValue(GameEditor.ColorToRGBA(c))
        end

        local roughVal = mat:GetShaderParameter("Roughness")
        if roughVal then
            local r = roughVal:GetFloat()
            if roughnessSlider_ then roughnessSlider_:SetValue(math.floor(r * 100 + 0.5)) end
            if roughnessLabel_ then roughnessLabel_:SetText("粗糙度: " .. math.floor(r * 100 + 0.5) .. "%") end
        end

        local metalVal = mat:GetShaderParameter("Metallic")
        if metalVal then
            local m = metalVal:GetFloat()
            if metallicSlider_ then metallicSlider_:SetValue(math.floor(m * 100 + 0.5)) end
            if metallicLabel_ then metallicLabel_:SetText("金属度: " .. math.floor(m * 100 + 0.5) .. "%") end
        end

        if materialOverrides_[selectedNodeName_] and materialOverrides_[selectedNodeName_].emissiveIntensity then
            local ei = math.floor(materialOverrides_[selectedNodeName_].emissiveIntensity * 100 + 0.5)
            if emissiveIntensitySlider_ then emissiveIntensitySlider_:SetValue(ei) end
            if emissiveIntensityLabel_ then emissiveIntensityLabel_:SetText("发光强度: " .. ei .. "%") end
        else
            if emissiveIntensitySlider_ then emissiveIntensitySlider_:SetValue(150) end
            if emissiveIntensityLabel_ then emissiveIntensityLabel_:SetText("发光强度: 150%") end
        end
    end
end

local function applyMaterial()
    if not selectedNode_ then return end
    local model = findStaticModel(selectedNode_)
    if not model then return end

    local GameEditor = require("editor.GameEditor")
    local rgba = colorPicker_:GetValue() or { 200, 200, 200, 255 }
    local color = GameEditor.RGBAToColor(rgba)
    local roughness = (roughnessSlider_:GetValue() or 92) / 100
    local metallic = (metallicSlider_:GetValue() or 0) / 100

    local newMat = Material:new()
    newMat:SetTechnique(0, cache:GetResource("Technique", GameConfig.Material.Technique))
    newMat:SetShaderParameter("MatDiffColor", Variant(color))
    newMat:SetShaderParameter("Roughness", Variant(roughness))
    newMat:SetShaderParameter("Metallic", Variant(metallic))

    local emissiveIntensity = (emissiveIntensitySlider_ and emissiveIntensitySlider_:GetValue() or 150) / 100
    if emissiveToggle_ and emissiveToggle_:GetValue() then
        newMat:SetShaderParameter("MatEmissiveColor", Variant(Color(
            color.r * emissiveIntensity, color.g * emissiveIntensity, color.b * emissiveIntensity
        )))
    end

    model:SetMaterial(newMat)

    materialOverrides_[selectedNodeName_] = {
        color = { color.r, color.g, color.b, color.a },
        roughness = roughness,
        metallic = metallic,
        emissive = emissiveToggle_ and emissiveToggle_:GetValue() or false,
        emissiveIntensity = emissiveIntensity,
    }
end

-- ============================================================================
-- 选中节点
-- ============================================================================

local function selectNode(node, name)
    selectedNode_ = node
    selectedNodeName_ = name
    refreshTransformUI()
    refreshMaterialUI()

    -- 自动展开变换和材质 section
    if sceneAccordion_ then
        sceneAccordion_:ExpandItem("transform")
        sceneAccordion_:ExpandItem("material")
    end
end

-- ============================================================================
-- 刷新节点列表
-- ============================================================================

local function refreshNodeList()
    if not nodeListPanel_ then return end
    UIHelper.DestroyChildren(nodeListPanel_)

    local nodes = getSceneNodes()
    local query = nodeSearchQuery_:lower()
    local visibleCount = 0

    for _, node in ipairs(nodes) do
        local name = node.name or "unnamed"
        -- 搜索过滤
        if query == "" or name:lower():find(query, 1, true) then
            visibleCount = visibleCount + 1
            local isSelected = (node == selectedNode_)
            local btn = UI.Button {
                text = name,
                fontSize = 11,
                backgroundColor = isSelected and { 50, 65, 95, 255 } or { 40, 40, 55, 255 },
                hoverBackgroundColor = { 55, 55, 75, 255 },
                textColor = isSelected and { 255, 220, 140, 255 } or { 200, 200, 210, 255 },
                paddingVertical = 4,
                paddingHorizontal = 8,
                marginBottom = 2,
                onClick = function(self)
                    selectNode(node, name)
                end,
            }
            nodeListPanel_:AddChild(btn)
        end
    end

    if nodeCountLabel_ then
        if query ~= "" then
            nodeCountLabel_:SetText(visibleCount .. "/" .. #nodes .. " 个节点")
        else
            nodeCountLabel_:SetText(#nodes .. " 个节点")
        end
    end
end

-- ============================================================================
-- 辅助：创建 TextField 行
-- ============================================================================

local function createFieldRow(label, defaultVal)
    local field = UI.TextField {
        value = defaultVal or "0",
        fontSize = 12,
        flexGrow = 1,
        flexBasis = 0,
        onSubmit = function(self, val) applyTransform() end,
        onBlur = function(self) applyTransform() end,
    }
    local row = UI.Panel {
        flexDirection = "row",
        alignItems = "center",
        gap = 6,
        marginBottom = 4,
        children = {
            UI.Label { text = label, fontSize = 12, fontColor = { 160, 160, 170, 255 }, width = 25 },
            field,
        },
    }
    return row, field
end

-- ============================================================================
-- 构建各 Accordion section 的内容 Widget
-- ============================================================================

local function buildNodeListContent()
    selectedLabel_ = UI.Label {
        text = "未选中",
        fontSize = 12,
        fontColor = { 200, 180, 120, 255 },
        marginBottom = 6,
    }

    nodeSearchField_ = UI.TextField {
        value = "",
        placeholder = "搜索节点...",
        fontSize = 11,
        marginBottom = 4,
        onChange = function(self, val)
            nodeSearchQuery_ = val or ""
            refreshNodeList()
        end,
    }

    nodeCountLabel_ = UI.Label {
        text = "0 个节点",
        fontSize = 10,
        fontColor = { 120, 120, 140, 200 },
        marginBottom = 4,
    }

    nodeListPanel_ = UI.Panel { gap = 2 }

    return UI.Panel {
        children = {
            selectedLabel_,
            nodeSearchField_,
            nodeCountLabel_,
            UI.ScrollView {
                maxHeight = 200,
                showScrollbar = true,
                padding = 4,
                children = { nodeListPanel_ },
            },
        },
    }
end

local function buildTransformContent()
    local posXRow, posXF = createFieldRow("X", "0")
    local posYRow, posYF = createFieldRow("Y", "0")
    local posZRow, posZF = createFieldRow("Z", "0")
    posXField_ = posXF
    posYField_ = posYF
    posZField_ = posZF

    local scaleXRow, scaleXF = createFieldRow("X", "1")
    local scaleYRow, scaleYF = createFieldRow("Y", "1")
    local scaleZRow, scaleZF = createFieldRow("Z", "1")
    scaleXField_ = scaleXF
    scaleYField_ = scaleYF
    scaleZField_ = scaleZF

    -- 三轴旋转滑块
    rotXLabel_ = UI.Label { text = "X: 0°", fontSize = 11, fontColor = { 160, 160, 170, 255 }, marginBottom = 2 }
    rotXSlider_ = UI.Slider {
        value = 0, min = -180, max = 180, step = 1,
        onChange = function(self, val) applyRotation("X", val) end,
    }
    rotYLabel_ = UI.Label { text = "Y: 0°", fontSize = 11, fontColor = { 160, 160, 170, 255 }, marginTop = 4, marginBottom = 2 }
    rotYSlider_ = UI.Slider {
        value = 0, min = 0, max = 360, step = 1,
        onChange = function(self, val) applyRotation("Y", val) end,
    }
    rotZLabel_ = UI.Label { text = "Z: 0°", fontSize = 11, fontColor = { 160, 160, 170, 255 }, marginTop = 4, marginBottom = 2 }
    rotZSlider_ = UI.Slider {
        value = 0, min = -180, max = 180, step = 1,
        onChange = function(self, val) applyRotation("Z", val) end,
    }

    shadowToggle_ = UI.Toggle {
        checked = true,
        onChange = function(self, checked) applyTransform() end,
    }

    -- 吸附控件
    snapToggle_ = UI.Toggle {
        checked = false,
        onChange = function(self, checked)
            snapEnabled_ = checked
            UI.Toast.Show(snapEnabled_ and "吸附已开启" or "吸附已关闭", { variant = "info", duration = 1 })
        end,
    }
    snapStepDropdown_ = UI.Dropdown {
        options = {
            { value = 0.25, label = "0.25m" },
            { value = 0.5,  label = "0.5m" },
            { value = 1.0,  label = "1.0m" },
            { value = 2.0,  label = "2.0m" },
            { value = 5.0,  label = "5.0m" },
        },
        value = 1.0,
        fontSize = 11,
        onChange = function(self, val) snapStep_ = val end,
    }

    return UI.Panel {
        children = {
            -- 位置
            UI.Label { text = "位置", fontSize = 11, fontWeight = "bold", fontColor = { 140, 180, 220, 255 }, marginBottom = 4 },
            posXRow, posYRow, posZRow,

            -- 缩放
            UI.Label { text = "缩放", fontSize = 11, fontWeight = "bold", fontColor = { 140, 180, 220, 255 }, marginTop = 6, marginBottom = 4 },
            scaleXRow, scaleYRow, scaleZRow,

            -- 旋转
            UI.Label { text = "旋转", fontSize = 11, fontWeight = "bold", fontColor = { 140, 180, 220, 255 }, marginTop = 6, marginBottom = 4 },
            rotXLabel_, rotXSlider_,
            rotYLabel_, rotYSlider_,
            rotZLabel_, rotZSlider_,

            -- 阴影
            UI.Panel {
                flexDirection = "row", alignItems = "center", gap = 8, marginTop = 6,
                children = {
                    UI.Label { text = "投射阴影", fontSize = 11, fontColor = { 160, 160, 170, 255 } },
                    shadowToggle_,
                },
            },

            -- 分隔线
            UI.Panel { height = 1, backgroundColor = { 45, 45, 55, 255 }, marginVertical = 8 },

            -- 吸附
            UI.Label { text = "吸附设置", fontSize = 11, fontWeight = "bold", fontColor = { 140, 180, 220, 255 }, marginBottom = 4 },
            UI.Panel {
                flexDirection = "row", alignItems = "center", gap = 8, marginBottom = 4,
                children = {
                    UI.Label { text = "启用吸附", fontSize = 11, fontColor = { 160, 160, 170, 255 } },
                    snapToggle_,
                },
            },
            UI.Panel {
                flexDirection = "row", alignItems = "center", gap = 6,
                children = {
                    UI.Label { text = "步长", fontSize = 11, fontColor = { 160, 160, 170, 255 }, width = 30 },
                    snapStepDropdown_,
                },
            },

            -- 贴地
            UI.Button {
                text = "贴地对齐",
                fontSize = 11,
                variant = "secondary",
                marginTop = 8,
                onClick = function(self) alignToGround() end,
            },
        },
    }
end

local function buildMaterialContent()
    colorPicker_ = UI.ColorPicker {
        value = { 200, 200, 200, 255 },
        showAlpha = false,
        onChange = function(self, color) applyMaterial() end,
    }

    roughnessLabel_ = UI.Label { text = "粗糙度: 92%", fontSize = 11, fontColor = { 160, 160, 170, 255 }, marginTop = 6, marginBottom = 2 }
    roughnessSlider_ = UI.Slider {
        value = 92, min = 0, max = 100, step = 1,
        onChangeEnd = function(self, val)
            if roughnessLabel_ then roughnessLabel_:SetText("粗糙度: " .. val .. "%") end
            applyMaterial()
        end,
        onChange = function(self, val)
            if roughnessLabel_ then roughnessLabel_:SetText("粗糙度: " .. val .. "%") end
        end,
    }

    metallicLabel_ = UI.Label { text = "金属度: 0%", fontSize = 11, fontColor = { 160, 160, 170, 255 }, marginTop = 6, marginBottom = 2 }
    metallicSlider_ = UI.Slider {
        value = 0, min = 0, max = 100, step = 1,
        onChangeEnd = function(self, val)
            if metallicLabel_ then metallicLabel_:SetText("金属度: " .. val .. "%") end
            applyMaterial()
        end,
        onChange = function(self, val)
            if metallicLabel_ then metallicLabel_:SetText("金属度: " .. val .. "%") end
        end,
    }

    emissiveToggle_ = UI.Toggle { checked = false, onChange = function(self, checked) applyMaterial() end }

    emissiveIntensityLabel_ = UI.Label { text = "发光强度: 150%", fontSize = 11, fontColor = { 160, 160, 170, 255 }, marginTop = 4, marginBottom = 2 }
    emissiveIntensitySlider_ = UI.Slider {
        value = 150, min = 50, max = 500, step = 10,
        onChange = function(self, val)
            if emissiveIntensityLabel_ then emissiveIntensityLabel_:SetText("发光强度: " .. val .. "%") end
        end,
        onChangeEnd = function(self, val)
            if emissiveIntensityLabel_ then emissiveIntensityLabel_:SetText("发光强度: " .. val .. "%") end
            applyMaterial()
        end,
    }

    return UI.Panel {
        children = {
            colorPicker_,
            roughnessLabel_, roughnessSlider_,
            metallicLabel_, metallicSlider_,
            UI.Panel {
                flexDirection = "row", alignItems = "center", gap = 8, marginTop = 6,
                children = {
                    UI.Label { text = "自发光", fontSize = 11, fontColor = { 160, 160, 170, 255 } },
                    emissiveToggle_,
                },
            },
            emissiveIntensityLabel_, emissiveIntensitySlider_,
        },
    }
end

local function buildAddObjectContent()
    addModelDropdown_ = UI.Dropdown {
        options = MODEL_OPTIONS,
        value = "Models/Box.mdl",
        placeholder = "选择模型",
        fontSize = 12,
    }

    return UI.Panel {
        children = {
            addModelDropdown_,
            UI.Button {
                text = "在前方新增物体",
                fontSize = 12,
                variant = "primary",
                marginTop = 6,
                onClick = function(self) EditorSceneTab.AddObject() end,
            },
        },
    }
end

-- ============================================================================
-- 构建环境光照 section
-- ============================================================================

local function buildEnvironmentContent()
    local GameEditor = require("editor.GameEditor")

    -- 环境光颜色（默认偏暖灰）
    ambientColorPicker_ = UI.ColorPicker {
        value = { 102, 102, 115, 255 },
        showAlpha = false,
        onChange = function(self, color) applyAmbientLight() end,
    }

    -- 太阳方向
    sunPitchLabel_ = UI.Label { text = "太阳高度: 45°", fontSize = 11, fontColor = { 160, 160, 170, 255 }, marginTop = 6, marginBottom = 2 }
    sunPitchSlider_ = UI.Slider {
        value = 45, min = 5, max = 90, step = 1,
        onChange = function(self, val)
            if sunPitchLabel_ then sunPitchLabel_:SetText("太阳高度: " .. math.floor(val + 0.5) .. "°") end
        end,
        onChangeEnd = function(self, val)
            if sunPitchLabel_ then sunPitchLabel_:SetText("太阳高度: " .. math.floor(val + 0.5) .. "°") end
            applySunLight()
        end,
    }

    sunYawLabel_ = UI.Label { text = "太阳方位: 30°", fontSize = 11, fontColor = { 160, 160, 170, 255 }, marginTop = 4, marginBottom = 2 }
    sunYawSlider_ = UI.Slider {
        value = 30, min = 0, max = 360, step = 1,
        onChange = function(self, val)
            if sunYawLabel_ then sunYawLabel_:SetText("太阳方位: " .. math.floor(val + 0.5) .. "°") end
        end,
        onChangeEnd = function(self, val)
            if sunYawLabel_ then sunYawLabel_:SetText("太阳方位: " .. math.floor(val + 0.5) .. "°") end
            applySunLight()
        end,
    }

    -- 太阳颜色
    sunColorPicker_ = UI.ColorPicker {
        value = { 255, 242, 217, 255 },
        showAlpha = false,
        onChange = function(self, color) applySunLight() end,
    }

    -- 太阳亮度
    sunBrightnessLabel_ = UI.Label { text = "太阳亮度: 120%", fontSize = 11, fontColor = { 160, 160, 170, 255 }, marginTop = 6, marginBottom = 2 }
    sunBrightnessSlider_ = UI.Slider {
        value = 120, min = 10, max = 300, step = 5,
        onChange = function(self, val)
            if sunBrightnessLabel_ then sunBrightnessLabel_:SetText("太阳亮度: " .. val .. "%") end
        end,
        onChangeEnd = function(self, val)
            if sunBrightnessLabel_ then sunBrightnessLabel_:SetText("太阳亮度: " .. val .. "%") end
            applySunLight()
        end,
    }

    return UI.Panel {
        children = {
            UI.Label { text = "环境光颜色", fontSize = 11, fontWeight = "bold", fontColor = { 140, 180, 220, 255 }, marginBottom = 4 },
            ambientColorPicker_,

            UI.Panel { height = 1, backgroundColor = { 45, 45, 55, 255 }, marginVertical = 8 },

            UI.Label { text = "太阳光", fontSize = 11, fontWeight = "bold", fontColor = { 140, 180, 220, 255 }, marginBottom = 4 },
            UI.Label { text = "颜色", fontSize = 10, fontColor = { 130, 130, 140, 255 }, marginBottom = 2 },
            sunColorPicker_,
            sunPitchLabel_, sunPitchSlider_,
            sunYawLabel_, sunYawSlider_,
            sunBrightnessLabel_, sunBrightnessSlider_,
        },
    }
end

-- ============================================================================
-- 构建雾效 section
-- ============================================================================

local function buildFogContent()
    fogToggle_ = UI.Toggle {
        checked = false,
        onChange = function(self, checked) applyFog() end,
    }

    fogColorPicker_ = UI.ColorPicker {
        value = { 179, 191, 204, 255 },
        showAlpha = false,
        onChange = function(self, color) applyFog() end,
    }

    fogStartLabel_ = UI.Label { text = "起始距离: 60m", fontSize = 11, fontColor = { 160, 160, 170, 255 }, marginTop = 6, marginBottom = 2 }
    fogStartSlider_ = UI.Slider {
        value = 60, min = 1, max = 200, step = 1,
        onChange = function(self, val)
            if fogStartLabel_ then fogStartLabel_:SetText("起始距离: " .. math.floor(val + 0.5) .. "m") end
        end,
        onChangeEnd = function(self, val)
            if fogStartLabel_ then fogStartLabel_:SetText("起始距离: " .. math.floor(val + 0.5) .. "m") end
            applyFog()
        end,
    }

    fogEndLabel_ = UI.Label { text = "消失距离: 200m", fontSize = 11, fontColor = { 160, 160, 170, 255 }, marginTop = 4, marginBottom = 2 }
    fogEndSlider_ = UI.Slider {
        value = 200, min = 50, max = 500, step = 5,
        onChange = function(self, val)
            if fogEndLabel_ then fogEndLabel_:SetText("消失距离: " .. math.floor(val + 0.5) .. "m") end
        end,
        onChangeEnd = function(self, val)
            if fogEndLabel_ then fogEndLabel_:SetText("消失距离: " .. math.floor(val + 0.5) .. "m") end
            applyFog()
        end,
    }

    return UI.Panel {
        children = {
            UI.Panel {
                flexDirection = "row", alignItems = "center", gap = 8, marginBottom = 6,
                children = {
                    UI.Label { text = "启用雾效", fontSize = 11, fontColor = { 160, 160, 170, 255 } },
                    fogToggle_,
                },
            },
            UI.Label { text = "雾颜色", fontSize = 10, fontColor = { 130, 130, 140, 255 }, marginBottom = 2 },
            fogColorPicker_,
            fogStartLabel_, fogStartSlider_,
            fogEndLabel_, fogEndSlider_,
        },
    }
end

-- ============================================================================
-- 构建节点操作 section
-- ============================================================================

local function buildNodeOpsContent()
    return UI.Panel {
        gap = 6,
        children = {
            UI.Label {
                text = "对选中节点执行操作",
                fontSize = 10,
                fontColor = { 130, 130, 140, 255 },
                marginBottom = 4,
            },
            UI.Button {
                text = "删除节点",
                fontSize = 12,
                backgroundColor = { 120, 40, 40, 255 },
                hoverBackgroundColor = { 160, 50, 50, 255 },
                textColor = { 255, 200, 200, 255 },
                onClick = function(self)
                    EditorSceneTab.DeleteSelectedNode()
                end,
            },
            UI.Button {
                text = "复制节点",
                fontSize = 12,
                variant = "secondary",
                onClick = function(self)
                    EditorSceneTab.DuplicateSelectedNode()
                end,
            },
            UI.Button {
                text = "传送到节点位置",
                fontSize = 12,
                variant = "secondary",
                onClick = function(self)
                    EditorSceneTab.TeleportToSelectedNode()
                end,
            },
        },
    }
end

-- ============================================================================
-- 创建场景面板（唯一的公开 Create 函数）
-- ============================================================================

function EditorSceneTab.CreateScenePanel()
    local nodeListContent = buildNodeListContent()
    local transformContent = buildTransformContent()
    local materialContent = buildMaterialContent()
    local addObjContent = buildAddObjectContent()
    local envContent = buildEnvironmentContent()
    local fogContent = buildFogContent()
    local nodeOpsContent = buildNodeOpsContent()

    sceneAccordion_ = UI.Accordion {
        items = {
            { id = "nodes",     title = "节点列表",    content = nodeListContent,   defaultExpanded = true },
            { id = "transform", title = "变换属性",    content = transformContent,  defaultExpanded = false },
            { id = "material",  title = "材质属性",    content = materialContent,   defaultExpanded = false },
            { id = "nodeops",   title = "节点操作",    content = nodeOpsContent,    defaultExpanded = false },
            { id = "addobj",    title = "新增物体",    content = addObjContent,     defaultExpanded = false },
            { id = "env",       title = "环境光照",    content = envContent,        defaultExpanded = false },
            { id = "fog",       title = "雾效",        content = fogContent,        defaultExpanded = false },
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
                children = { sceneAccordion_ },
            },
        },
    }
end

-- ============================================================================
-- 节点操作
-- ============================================================================

function EditorSceneTab.DeleteSelectedNode()
    if not selectedNode_ then
        UI.Toast.Show("请先选中节点", { variant = "warning", duration = 2 })
        return
    end

    local name = selectedNodeName_
    -- 不允许删除地面
    if name == "Ground" then
        UI.Toast.Show("不能删除地面", { variant = "error", duration = 2 })
        return
    end

    selectedNode_:Remove()
    selectedNode_ = nil
    selectedNodeName_ = ""

    -- 清除覆盖记录
    sceneOverrides_[name] = nil
    materialOverrides_[name] = nil

    refreshNodeList()
    refreshTransformUI()

    UI.Toast.Show("已删除: " .. name, { variant = "success", duration = 2 })
    print("[EditorSceneTab] 删除节点: " .. name)
end

function EditorSceneTab.DuplicateSelectedNode()
    if not selectedNode_ then
        UI.Toast.Show("请先选中节点", { variant = "warning", duration = 2 })
        return
    end

    local village = scene_:GetChild("Village")
    if not village then return end

    addCounter_ = addCounter_ + 1
    local newName = selectedNodeName_ .. "_copy" .. addCounter_

    local newNode = village:CreateChild(newName)
    newNode.position = selectedNode_.position + Vector3(2, 0, 0) -- 偏移2米
    newNode.scale = selectedNode_.scale
    newNode.rotation = selectedNode_.rotation

    -- 复制 StaticModel
    local srcModel = findStaticModel(selectedNode_)
    if srcModel then
        local dstModel = newNode:CreateComponent("StaticModel")
        dstModel:SetModel(srcModel:GetModel())
        dstModel:SetMaterial(srcModel:GetMaterial(0))
        dstModel.castShadows = srcModel.castShadows
    end

    refreshNodeList()
    selectNode(newNode, newName)

    UI.Toast.Show("已复制: " .. newName, { variant = "success", duration = 2 })
    print("[EditorSceneTab] 复制节点: " .. selectedNodeName_ .. " -> " .. newName)
end

function EditorSceneTab.TeleportToSelectedNode()
    if not selectedNode_ then
        UI.Toast.Show("请先选中节点", { variant = "warning", duration = 2 })
        return
    end

    if not fpController_ then return end

    local camNode = fpController_:GetCameraNode()
    if not camNode then return end

    local targetPos = selectedNode_.position
    -- 传送到节点附近（偏移3米+站立高度）
    camNode.position = Vector3(targetPos.x + 3, targetPos.y + 1.6, targetPos.z)

    UI.Toast.Show("已传送到: " .. selectedNodeName_, { variant = "success", duration = 2 })
    print("[EditorSceneTab] 传送到节点: " .. selectedNodeName_)
end

-- ============================================================================
-- 新增物体
-- ============================================================================

function EditorSceneTab.AddObject()
    if not scene_ or not fpController_ then return end

    local village = scene_:GetChild("Village")
    if not village then return end

    local modelPath = addModelDropdown_:GetValue() or "Models/Box.mdl"
    addCounter_ = addCounter_ + 1
    local name = "EditorObj_" .. addCounter_

    local camNode = fpController_:GetCameraNode()
    local camPos = camNode.position
    local camDir = camNode.rotation * Vector3.FORWARD
    local spawnPos = Vector3(camPos.x + camDir.x * 5, 0.5, camPos.z + camDir.z * 5)

    local node = village:CreateChild(name)
    node.position = spawnPos

    local model = node:CreateComponent("StaticModel")
    model:SetModel(cache:GetResource("Model", modelPath))
    model:SetMaterial(GameConfig.CreateMaterial(Color(0.6, 0.6, 0.6, 1.0)))
    model.castShadows = true

    refreshNodeList()
    selectNode(node, name)

    UI.Toast.Show("已创建: " .. name, { variant = "success", duration = 2 })
end

-- ============================================================================
-- 公开接口
-- ============================================================================

function EditorSceneTab.Init(scene, controller)
    scene_ = scene
    fpController_ = controller

    -- 初始化环境组件
    findOrCreateZone()
    findSunLight()
end

local function refreshEnvironmentUI()
    local GameEditor = require("editor.GameEditor")

    -- 刷新环境光
    local z = findOrCreateZone()
    if z and ambientColorPicker_ then
        ambientColorPicker_:SetValue(GameEditor.ColorToRGBA(z.ambientColor))
    end

    -- 刷新太阳光
    local light, node = findSunLight()
    if light and node then
        local euler = node.rotation:EulerAngles()
        local pitch = euler.x
        local yaw = euler.y

        if sunPitchSlider_ then sunPitchSlider_:SetValue(math.max(5, math.min(90, math.floor(pitch + 0.5)))) end
        if sunPitchLabel_ then sunPitchLabel_:SetText("太阳高度: " .. math.floor(pitch + 0.5) .. "°") end
        if sunYawSlider_ then sunYawSlider_:SetValue(math.max(0, math.min(360, math.floor(yaw + 0.5)))) end
        if sunYawLabel_ then sunYawLabel_:SetText("太阳方位: " .. math.floor(yaw + 0.5) .. "°") end

        if sunColorPicker_ then
            sunColorPicker_:SetValue(GameEditor.ColorToRGBA(light.color))
        end

        local brightnessVal = math.floor(light.brightness * 100 + 0.5)
        if sunBrightnessSlider_ then sunBrightnessSlider_:SetValue(brightnessVal) end
        if sunBrightnessLabel_ then sunBrightnessLabel_:SetText("太阳亮度: " .. brightnessVal .. "%") end
    end

    -- 刷新雾效
    if z then
        local fogEnabled = z.fogStart < 8000
        if fogToggle_ then fogToggle_:SetValue(fogEnabled) end

        if fogEnabled then
            if fogColorPicker_ then fogColorPicker_:SetValue(GameEditor.ColorToRGBA(z.fogColor)) end
            local fs = math.floor(z.fogStart + 0.5)
            local fe = math.floor(z.fogEnd + 0.5)
            if fogStartSlider_ then fogStartSlider_:SetValue(fs) end
            if fogStartLabel_ then fogStartLabel_:SetText("起始距离: " .. fs .. "m") end
            if fogEndSlider_ then fogEndSlider_:SetValue(fe) end
            if fogEndLabel_ then fogEndLabel_:SetText("消失距离: " .. fe .. "m") end
        end
    end
end

function EditorSceneTab.Refresh()
    refreshNodeList()
    refreshTransformUI()
    refreshMaterialUI()
    refreshEnvironmentUI()
end

function EditorSceneTab.Update(dt) end

function EditorSceneTab.GetOverrides()
    return sceneOverrides_
end

function EditorSceneTab.GetMaterialOverrides()
    return materialOverrides_
end

function EditorSceneTab.ApplyOverrides(overrides)
    if not overrides then return end
    local village = scene_:GetChild("Village")
    if not village then return end

    for name, data in pairs(overrides) do
        local node = village:GetChild(name)
        if node then
            if data.pos then node.position = Vector3(data.pos[1], data.pos[2], data.pos[3]) end
            if data.scale then node.scale = Vector3(data.scale[1], data.scale[2], data.scale[3]) end
            -- 支持三轴旋转（向后兼容只有 rotY 的旧数据）
            local rx = data.rotX or 0
            local ry = data.rotY or 0
            local rz = data.rotZ or 0
            node.rotation = Quaternion(rx, ry, rz)
            if data.castShadows ~= nil then
                local model = findStaticModel(node)
                if model then model.castShadows = data.castShadows end
            end
            sceneOverrides_[name] = data
        end
    end
end

function EditorSceneTab.GetEnvOverrides()
    return envOverrides_
end

function EditorSceneTab.ApplyEnvOverrides(overrides)
    if not overrides then return end

    local GameEditor = require("editor.GameEditor")

    -- 环境光
    if overrides.ambientColor then
        local z = findOrCreateZone()
        if z then
            z.ambientColor = GameEditor.RGBAToColor(overrides.ambientColor)
        end
    end

    -- 太阳光
    local light, node = findSunLight()
    if light and node then
        if overrides.sunPitch and overrides.sunYaw then
            node.rotation = Quaternion(overrides.sunPitch, overrides.sunYaw, 0)
        end
        if overrides.sunColor then
            light.color = GameEditor.RGBAToColor(overrides.sunColor)
        end
        if overrides.sunBrightness then
            light.brightness = overrides.sunBrightness / 100
        end
    end

    -- 雾效
    local z = findOrCreateZone()
    if z then
        if overrides.fogEnabled then
            if overrides.fogColor then
                z.fogColor = GameEditor.RGBAToColor(overrides.fogColor)
            end
            z.fogStart = overrides.fogStart or 60
            z.fogEnd = overrides.fogEnd or 200
        else
            z.fogStart = 9000
            z.fogEnd = 10000
        end
    end

    envOverrides_ = overrides
end

function EditorSceneTab.ApplyMaterialOverrides(overrides)
    if not overrides then return end
    local village = scene_:GetChild("Village")
    if not village then return end

    for name, data in pairs(overrides) do
        local node = village:GetChild(name)
        if not node then goto continue end

        local model = findStaticModel(node)
        if model and data.color then
            local color = Color(data.color[1], data.color[2], data.color[3], data.color[4] or 1.0)
            local newMat = Material:new()
            newMat:SetTechnique(0, cache:GetResource("Technique", GameConfig.Material.Technique))
            newMat:SetShaderParameter("MatDiffColor", Variant(color))
            newMat:SetShaderParameter("Roughness", Variant(data.roughness or 0.92))
            newMat:SetShaderParameter("Metallic", Variant(data.metallic or 0.0))
            if data.emissive then
                local ei = data.emissiveIntensity or 1.5
                newMat:SetShaderParameter("MatEmissiveColor", Variant(Color(color.r * ei, color.g * ei, color.b * ei)))
            end
            model:SetMaterial(newMat)
        end
        materialOverrides_[name] = data
        ::continue::
    end
end

--- 获取当前选中的场景节点
---@return Node|nil
function EditorSceneTab.GetSelectedNode()
    return selectedNode_
end

return EditorSceneTab
