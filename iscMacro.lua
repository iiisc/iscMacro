-- iscMacro: macros generated from shared templates.
-- A template is macro text with {placeholders}; each different placeholder is a slot for a
-- spell or an item.
-- Every macro uses one template, so editing a template rewrites all of its macros.
-- Templates are account-wide (iscMacroTemplates), macros per character (iscMacroDB).
-- Type /isc or click the minimap button to open the window.

local DEFAULT_ICON = "INV_MISC_QUESTIONMARK" -- lets #showtooltip pick the icon
local UNKNOWN_ICON = "Interface\\Icons\\" .. DEFAULT_ICON
local MAX_BODY, MAX_NAME = 255, 16
local MAX_SLOTS = 6 -- the 255-character limit makes more slots per macro impractical
local PLACEHOLDER = "{([%w_]+)}"
-- Classic can't cast on focus and @cursor still needs a second click, so neither is used here.
local DEFAULT_TEMPLATES = {
    { name = "Help / Harm",
      text = "#showtooltip\n/cast [mod:alt,@player] {friendly}; [harm,nodead] {enemy}; [help,nodead] {friendly}; [@player] {friendly}" },
    { name = "Heal (mouseover)",
      text = "#showtooltip\n/cast [mod:alt,@player] [@mouseover,help,nodead] [help,nodead] [@targettarget,help,nodead] [@player] {heal}" },
    { name = "Harm (mouseover)",
      text = "#showtooltip\n/cast [@mouseover,harm,nodead] [harm,nodead] [@targettarget,harm,nodead] {spell}" },
    { name = "Modifiers",
      text = "#showtooltip\n/cast [mod:ctrl] {ctrl}; [mod:shift] {shift}; [mod:alt] {alt}; {spell}" },
    { name = "Don't clip channel",
      text = "#showtooltip\n/stopmacro [channeling]\n/cast {spell}" },
    { name = "Interrupt",
      text = "#showtooltip\n/stopcasting\n/cast {spell}" },
    { name = "Melee ability",
      text = "#showtooltip\n/startattack\n/cast {spell}" },
    { name = "Pet + spell",
      text = "#showtooltip\n/petattack\n/cast {spell}" },
    { name = "Trinkets + spell",
      text = "#showtooltip {spell}\n/use 13\n/use 14\n/cast {spell}" },
    { name = "Consumable chain",
      text = "#showtooltip\n/use {first}\n/use {second}" },
    { name = "Cast sequence",
      text = "#showtooltip\n/castsequence reset=target {first}, {second}" },
}

local pendingSync = false
local ui            -- the window, created on first use
local RefreshUI     -- defined further down

local function Print(msg)
    print("|cff66ccffiscMacro:|r " .. msg)
end

-- Placeholder names in order of first appearance.
local function Placeholders(text)
    local keys, seen = {}, {}
    for key in text:gmatch(PLACEHOLDER) do
        if not seen[key] then
            seen[key] = true
            keys[#keys + 1] = key
        end
    end
    return keys
end

local function SpellText(spell)
    if spell.exact and spell.rank then
        return ("%s(%s)"):format(spell.name, spell.rank)
    end
    return spell.name
end

-- Returns the macro text, or nil and why it can't be built.
-- text previews unsaved template edits instead of the saved template.
local function BuildBody(macro, text)
    local template = iscMacroTemplates.list[macro.template]
    text = text or (template and template.text)
    if not text then return nil, "its template was deleted" end
    local missing
    local body = text:gsub(PLACEHOLDER, function(key)
        local spell = macro.spells[key]
        if spell then return SpellText(spell) end
        missing = missing or key
    end)
    if missing then return nil, ("nothing in {%s}"):format(missing) end
    return body
end

-- Like BuildBody, but also refuses text the game won't accept.
local function CheckedBody(macro)
    local body, problem = BuildBody(macro)
    if body and #body > MAX_BODY then
        return nil, ("%d characters, max %d"):format(#body, MAX_BODY)
    end
    return body, problem
end

local function SortedTemplateIds()
    local list, ids = iscMacroTemplates.list, {}
    for id in pairs(list) do ids[#ids + 1] = id end
    table.sort(ids, function(a, b) return list[a].name:lower() < list[b].name:lower() end)
    return ids
end

local function TemplateUseCount(id)
    local count = 0
    for _, macro in pairs(iscMacroDB.macros) do
        if macro.template == id then count = count + 1 end
    end
    return count
end

-- Slot entries are spells unless kind == "item". The field is still called "spells" in saved data.
local function EntryIcon(entry)
    local icon
    if entry.kind == "item" then
        icon = C_Item.GetItemIconByID(entry.id)
    else
        icon = C_Spell.GetSpellTexture(entry.id)
    end
    return icon or UNKNOWN_ICON
end

local function OrderedSpells(macro)
    local template = iscMacroTemplates.list[macro.template]
    local spells = {}
    if template then
        for _, key in ipairs(Placeholders(template.text)) do
            spells[#spells + 1] = macro.spells[key]
        end
    end
    return spells
end

-- #showtooltip picks the icon itself; without it, use the first entry's icon.
local function MacroIcon(macro, body)
    local first = OrderedSpells(macro)[1]
    if first and not body:lower():find("#showtooltip", 1, true) then
        return EntryIcon(first)
    end
    return DEFAULT_ICON
end

-- This character's macros by name, as { index, body }. GetMacroIndexByName also finds
-- account-wide macros, which come first and belong to the user, so it must not be used to find
-- ours. Character macros start after a run of empty account slots whose size we don't rely on.
local function CharacterMacros()
    local numAccount, numCharacter = GetNumMacros()
    local macros, seen, index = {}, 0, numAccount + 1
    while seen < numCharacter and index <= numAccount + 1000 do
        local name, _, body = GetMacroInfo(index)
        if name then
            seen = seen + 1
            macros[name] = { index = index, body = body }
        end
        index = index + 1
    end
    return macros
end

local function CharacterMacroIndex(name)
    local macro = CharacterMacros()[name]
    return macro and macro.index
end

-- Macros can't be edited in combat, so this defers until combat ends. Returns true if it synced.
-- Unchanged macros are skipped: each EditMacro makes every action bar refresh.
local function Sync()
    if InCombatLockdown() then
        if not pendingSync then Print("Macros will update when you leave combat.") end
        pendingSync = true
        return false
    end
    pendingSync = false

    local existing = CharacterMacros()
    for name, macro in pairs(iscMacroDB.macros) do
        local body, problem = CheckedBody(macro)
        if not body then
            Print(("'%s' not updated: %s."):format(name, problem))
        elseif not existing[name] then
            local ok, index = pcall(CreateMacro, name, MacroIcon(macro, body), body, true)
            if ok and index then
                existing = CharacterMacros() -- macros are kept sorted, so creating one moves others
            else
                Print(("Couldn't create '%s' (are your character macro slots full?)"):format(name))
            end
        elseif existing[name].body ~= body then
            EditMacro(existing[name].index, name, MacroIcon(macro, body), body)
        end
    end
    return true
end

-- oldName is set when editing an existing macro.
local function SaveMacro(name, templateId, spells, oldName)
    local template = iscMacroTemplates.list[templateId]
    if not template then
        Print("Pick a template first.")
        return false
    end
    local keys = Placeholders(template.text)
    local macro = { template = templateId, spells = {} }
    for _, key in ipairs(keys) do
        if not spells[key] then
            Print(("Drag a spell or item onto {%s}."):format(key))
            return false
        end
        macro.spells[key] = spells[key] -- the form's entries are its own copies (see LoadForm)
    end

    name = strtrim(name or "")
    if name == "" and keys[1] then
        name = macro.spells[keys[1]].name:sub(1, MAX_NAME) -- default: the first spell's name
    end
    if name == "" then
        Print("Give the macro a name.")
        return false
    end
    if #name > MAX_NAME then
        Print(("Macro names are limited to %d characters."):format(MAX_NAME))
        return false
    end
    local renaming = oldName and oldName ~= name
    -- Sync edits whatever character macro has this name, so it must not adopt one the user
    -- wrote, nor replace another of ours.
    if name ~= oldName and (iscMacroDB.macros[name] or CharacterMacroIndex(name)) then
        Print(("This character already has a macro named '%s'. Pick another name."):format(name))
        return false
    end
    if renaming and InCombatLockdown() then
        Print("Can't rename macros in combat.")
        return false
    end
    if renaming then
        iscMacroDB.macros[oldName] = nil
        local index = CharacterMacroIndex(oldName)
        -- Renaming in place keeps the macro on the player's action bars.
        if index then
            EditMacro(index, name, nil, BuildBody(macro))
        end
    end
    iscMacroDB.macros[name] = macro
    Sync()
    Print(("Saved '%s'."):format(name))
    RefreshUI()
    return true
end

local function RemoveMacro(name)
    iscMacroDB.macros[name] = nil
    if InCombatLockdown() then
        Print(("Removed '%s' from the list. Delete the macro itself after combat."):format(name))
    else
        local index = CharacterMacroIndex(name)
        if index then DeleteMacro(index) end
        Print(("Removed '%s'."):format(name))
    end
    RefreshUI()
end

-- id is nil for a new template. Returns the template's id, or nil if it wasn't saved.
local function SaveTemplate(id, name, text)
    name, text = strtrim(name or ""), strtrim(text or "")
    if name == "" or text == "" then
        Print("A template needs a name and some text.")
        return
    end
    for otherId, template in pairs(iscMacroTemplates.list) do
        if otherId ~= id and template.name == name then
            Print(("There's already a template named '%s'."):format(name))
            return
        end
    end
    if #Placeholders(text) > MAX_SLOTS then
        Print(("A template can have at most %d slots."):format(MAX_SLOTS))
        return
    end
    if not id then
        id = iscMacroTemplates.nextId
        iscMacroTemplates.nextId = id + 1
    end
    iscMacroTemplates.list[id] = { name = name, text = text }
    Sync()
    Print(("Saved template '%s'."):format(name))
    RefreshUI()
    return id
end

local WIDTH, INNER_WIDTH = 440, 400
local PAGE_TOP = 56
local SLOTS_TOP, SLOT_HEIGHT = 100, 44
local ROW_HEIGHT, TEMPLATE_ROW_HEIGHT = 32, 24
local LIST_OFFSET = 64 -- from the top of the buttons below the slots to the first macro row
local EDITOR_HEIGHT = 224

-- The macro form's state: which macro is being edited (nil = new), its template, its entries.
local form = { spells = {} }
local macroRows, templateRows = {}, {}

-- Only subtexts with a number are ranks; others are labels like "Racial" or "Passive".
local function SpellRank(spellID)
    local subtext = C_Spell.GetSpellSubtext(spellID)
    return subtext and subtext:find("%d") and subtext or nil
end

-- What's on the cursor as a slot entry, or nil if it isn't a spell or an item.
local function CursorEntry()
    local kind, a, b, c = GetCursorInfo()
    if kind == "spell" and c then -- c = spell ID
        local name = C_Spell.GetSpellName(c)
        return name and { id = c, name = name, rank = SpellRank(c) }
    elseif kind == "item" and b then -- a = item ID, b = item link
        local name = b:match("%[(.-)%]")
        return name and { kind = "item", id = a, name = name }
    end
end

local function CreateText(parent, font, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", font)
    if text then fs:SetText(text) end
    return fs
end

local function CreateRule(parent)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.15)
    line:SetSize(INNER_WIDTH, 1)
    return line
end

local function CreateButton(parent, width, text, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, 22)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
end

local function CreateInputBox(parent, width, maxLetters)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, 20)
    box:SetAutoFocus(false)
    box:SetMaxLetters(maxLetters)
    box:SetScript("OnEnterPressed", box.ClearFocus)
    box:SetScript("OnEscapePressed", box.ClearFocus)
    return box
end

local function SimpleTooltip(owner, text)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText(text, 1, 1, 1, 1, true)
    GameTooltip:Show()
end

local function CreateListRow(parent, height, onDelete)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(INNER_WIDTH, height)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row:RegisterForClicks("LeftButtonUp")

    row.selected = row:CreateTexture(nil, "BACKGROUND")
    row.selected:SetAllPoints()
    row.selected:SetColorTexture(1, 0.82, 0, 0.12)

    row.del = CreateFrame("Button", nil, row)
    row.del:SetSize(18, 18)
    row.del:SetPoint("RIGHT", -4, 0)
    row.del:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    row.del:SetPushedTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Down")
    row.del:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Highlight", "ADD")
    row.del:SetScript("OnClick", function() onDelete(row) end)
    row.del:SetScript("OnEnter", function(self) SimpleTooltip(self, "Delete") end)
    row.del:SetScript("OnLeave", GameTooltip_Hide)

    row.title = CreateText(row, "GameFontNormal")
    row.title:SetJustifyH("LEFT")
    row.title:SetWordWrap(false)

    row.sub = CreateText(row, "GameFontDisableSmall")
    row.sub:SetPoint("RIGHT", row.del, "LEFT", -6, 0)
    row.sub:SetJustifyH("LEFT")
    row.sub:SetWordWrap(false)
    return row
end

local function CreatePage()
    local page = CreateFrame("Frame", nil, ui)
    page:SetPoint("TOPLEFT", 0, -PAGE_TOP)
    page:SetWidth(WIDTH)
    return page
end

local function DefineConfirm(key, text, onAccept)
    StaticPopupDialogs[key] = {
        text = text,
        button1 = YES,
        button2 = NO,
        OnAccept = function(_, data) onAccept(data) end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
end

local function RenderSlotLine(line)
    local spell = form.spells[line.key]
    if spell then
        line.icon:SetTexture(EntryIcon(spell))
        line.text:SetText(spell.rank and ("%s\n|cff808080%s|r"):format(spell.name, spell.rank) or spell.name)
    else
        line.icon:SetTexture(nil)
        line.text:SetText("|cff808080Drag a spell or item here|r")
    end
    local hasRank = spell ~= nil and spell.rank ~= nil
    line.exact:SetEnabled(hasRank)
    line.exact:SetChecked(hasRank and spell.exact)
    local shade = hasRank and 1 or 0.5
    line.exactLabel:SetTextColor(shade, shade, shade)
end

local function SlotAcceptCursor(slot)
    local line = slot:GetParent()
    local entry = CursorEntry()
    if not entry then
        Print("Drag a spell from your spellbook or an item from your bags onto the slot.")
        return
    end
    local old = form.spells[line.key]
    entry.exact = old and old.exact
    form.spells[line.key] = entry
    ClearCursor()
    RenderSlotLine(line)
end

local function CreateSlotLine(parent)
    local line = CreateFrame("Frame", nil, parent)
    line:SetSize(INNER_WIDTH, 36)

    line.label = CreateText(line, "GameFontNormalSmall")
    line.label:SetPoint("LEFT")
    line.label:SetWidth(64)
    line.label:SetJustifyH("LEFT")

    local slot = CreateFrame("Button", nil, line)
    slot:SetSize(36, 36)
    slot:SetPoint("LEFT", 70, 0)
    local bg = slot:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
    line.icon = slot:CreateTexture(nil, "ARTWORK")
    line.icon:SetAllPoints()
    slot:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    slot:RegisterForClicks("AnyUp")
    slot:SetScript("OnReceiveDrag", SlotAcceptCursor)
    slot:SetScript("OnClick", function(self, button)
        if GetCursorInfo() then
            SlotAcceptCursor(self)
        elseif button == "RightButton" then
            form.spells[line.key] = nil
            RenderSlotLine(line)
        end
    end)
    slot:SetScript("OnEnter", function(self)
        SimpleTooltip(self, form.spells[line.key]
            and "Drag another spell or item here to replace it. Right-click to clear."
            or "Drag a spell from your spellbook or an item from your bags.")
    end)
    slot:SetScript("OnLeave", GameTooltip_Hide)

    line.text = CreateText(line, "GameFontHighlightSmall")
    line.text:SetPoint("LEFT", slot, "RIGHT", 8, 0)
    line.text:SetWidth(190)
    line.text:SetJustifyH("LEFT")

    line.exact = CreateFrame("CheckButton", nil, line, "UICheckButtonTemplate")
    line.exact:SetSize(24, 24)
    line.exact:SetPoint("LEFT", 312, 0)
    line.exact:SetScript("OnClick", function(self)
        local spell = form.spells[line.key]
        if spell then spell.exact = self:GetChecked() end
    end)
    line.exact:SetScript("OnEnter", function(self)
        SimpleTooltip(self, "Cast this exact rank instead of your highest rank.")
    end)
    line.exact:SetScript("OnLeave", GameTooltip_Hide)

    line.exactLabel = CreateText(line, "GameFontHighlightSmall", "Exact rank")
    line.exactLabel:SetPoint("LEFT", line.exact, "RIGHT", 0, 1)
    return line
end

-- Loads a macro into the form for editing; nil resets it to create a new one.
-- The template choice is kept on reset, for making several macros from one template.
local function LoadForm(name)
    local macro = name and iscMacroDB.macros[name]
    form.editing = name
    form.spells = {}
    if macro then
        form.template = macro.template
        for key, spell in pairs(macro.spells) do
            form.spells[key] = CopyTable(spell)
        end
    end
    ui.nameBox:SetText(name or "")
    ui.nameBox:ClearFocus()
    RefreshUI()
end

local function InitTemplateDropDown(_, level)
    for _, id in ipairs(SortedTemplateIds()) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = iscMacroTemplates.list[id].name
        info.checked = id == form.template
        info.func = function()
            form.template = id
            RefreshUI()
        end
        UIDropDownMenu_AddButton(info, level)
    end
end

local function MacroTooltip(row)
    local body, problem = CheckedBody(iscMacroDB.macros[row.name])
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetText(row.name)
    if body then
        GameTooltip:AddLine(body, 0.8, 0.8, 0.8, true)
    else
        GameTooltip:AddLine("Not updated: " .. problem, 1, 0.25, 0.25, true)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Drag to an action bar. Click to edit.", 0, 1, 0, true)
    GameTooltip:Show()
end

local function GetMacroRow(i)
    if macroRows[i] then return macroRows[i] end

    local row = CreateListRow(ui.macroList, ROW_HEIGHT - 2, function(self)
        StaticPopup_Show("ISCMACRO_DELETE_MACRO", self.name, nil, self.name)
    end)
    row:SetPoint("TOPLEFT", 20, -(LIST_OFFSET + (i - 1) * ROW_HEIGHT))
    row:RegisterForDrag("LeftButton")
    row:SetScript("OnClick", function(self) LoadForm(self.name) end)
    row:SetScript("OnDragStart", function(self)
        if InCombatLockdown() then
            Print("Can't pick up macros in combat.")
        else
            local index = CharacterMacroIndex(self.name)
            if index then PickupMacro(index) end
        end
    end)
    row:SetScript("OnEnter", MacroTooltip)
    row:SetScript("OnLeave", GameTooltip_Hide)

    row.icons = {}
    for n = 1, 4 do
        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(24, 24)
        icon:SetPoint("LEFT", 3 + (n - 1) * 26, 0)
        row.icons[n] = icon
    end
    row.title:SetPoint("RIGHT", row.del, "LEFT", -6, 0)

    macroRows[i] = row
    return row
end

local function RefreshMacros()
    local templates = iscMacroTemplates.list
    if not form.editing and not templates[form.template] then
        form.template = SortedTemplateIds()[1]
    end
    local template = templates[form.template]

    ui.formTitle:SetText(form.editing and ("Editing '%s'"):format(form.editing) or "New macro")
    UIDropDownMenu_SetText(ui.templateDropDown, template and template.name or "Pick a template")

    local keys = template and Placeholders(template.text) or {}
    for i, line in ipairs(ui.slotLines) do
        line.key = keys[i]
        line:SetShown(keys[i] ~= nil)
        if keys[i] then
            line.label:SetText(keys[i])
            RenderSlotLine(line)
        end
    end
    ui.noSlots:SetShown(#keys == 0)
    ui.noSlots:SetText(not next(templates) and "Create a template on the Templates tab first."
        or not template and "Pick a template."
        or "This template has no slots.")

    local listTop = SLOTS_TOP + math.max(#keys, 1) * SLOT_HEIGHT + 4
    ui.macroList:SetPoint("TOPLEFT", 0, -listTop)
    ui.addButton:SetText(form.editing and "Save changes" or "Create macro")
    ui.cancelButton:SetShown(form.editing ~= nil)
    ui.copyButton:SetShown(form.editing ~= nil)

    -- The limit counts every character macro, not just ours. The fallback only guards against
    -- the macro UI not defining the constant; the window loads that UI first.
    local _, used = GetNumMacros()
    local max = MAX_CHARACTER_MACROS or 18
    ui.slotCount:SetText(("%s%d of %d character macro slots used|r")
        :format(used >= max and "|cffff4040" or "|cff808080", used, max))

    local names = {}
    for name in pairs(iscMacroDB.macros) do names[#names + 1] = name end
    table.sort(names)

    for i, name in ipairs(names) do
        local macro = iscMacroDB.macros[name]
        local row = GetMacroRow(i)
        row.name = name

        local spells = OrderedSpells(macro)
        local shown = math.min(#spells, #row.icons)
        for n, icon in ipairs(row.icons) do
            icon:SetShown(n <= shown)
            if n <= shown then icon:SetTexture(EntryIcon(spells[n])) end
        end
        local x = 3 + shown * 26 + 6
        row.title:SetPoint("TOPLEFT", x, -2)
        row.sub:SetPoint("BOTTOMLEFT", x, 2)
        row.title:SetText(name)

        local _, problem = CheckedBody(macro)
        row.sub:SetText(problem and ("|cffff4040Not updated: %s|r"):format(problem)
            or templates[macro.template].name)
        row.selected:SetShown(name == form.editing)
        row:Show()
    end
    for i = #names + 1, #macroRows do macroRows[i]:Hide() end

    ui.macrosEmpty:SetShown(#names == 0)
    ui.macrosPage:SetHeight(listTop + LIST_OFFSET + math.max(#names, 1) * ROW_HEIGHT)
end

local function CreateMacrosPage()
    local page = CreatePage()
    ui.macrosPage = page

    ui.formTitle = CreateText(page, "GameFontNormal")
    ui.formTitle:SetPoint("TOPLEFT", 20, -8)

    local templateLabel = CreateText(page, "GameFontHighlightSmall", "Template")
    templateLabel:SetPoint("TOPLEFT", 20, -40)
    -- The stock dropdown template looks its parts up by global name, so it needs one.
    ui.templateDropDown = CreateFrame("Frame", "iscMacroTemplateDropDown", page, "UIDropDownMenuTemplate")
    ui.templateDropDown:SetPoint("LEFT", templateLabel, "LEFT", 40, -2)
    UIDropDownMenu_SetWidth(ui.templateDropDown, 180)
    UIDropDownMenu_Initialize(ui.templateDropDown, InitTemplateDropDown)

    local nameLabel = CreateText(page, "GameFontHighlightSmall", "Name")
    nameLabel:SetPoint("TOPLEFT", 20, -72)
    ui.nameBox = CreateInputBox(page, 160, MAX_NAME)
    ui.nameBox:SetPoint("LEFT", nameLabel, "LEFT", 62, 0)
    local placeholder = CreateText(ui.nameBox, "GameFontDisableSmall", "Optional")
    placeholder:SetPoint("LEFT", 2, 0)
    ui.nameBox:HookScript("OnTextChanged", function(self)
        placeholder:SetShown(self:GetText() == "")
    end)

    ui.slotLines = {}
    for i = 1, MAX_SLOTS do
        local line = CreateSlotLine(page)
        line:SetPoint("TOPLEFT", 20, -(SLOTS_TOP + (i - 1) * SLOT_HEIGHT))
        ui.slotLines[i] = line
    end
    ui.noSlots = CreateText(page, "GameFontDisableSmall")
    ui.noSlots:SetPoint("TOPLEFT", 20, -(SLOTS_TOP + 12))

    -- Everything below the slots moves as one block when the slot count changes.
    local list = CreateFrame("Frame", nil, page)
    list:SetSize(WIDTH, 1)
    ui.macroList = list

    ui.addButton = CreateButton(list, 120, "Create macro", function()
        if SaveMacro(ui.nameBox:GetText(), form.template, form.spells, form.editing) then
            LoadForm()
        end
    end)
    ui.addButton:SetPoint("TOPLEFT", 20, 0)
    ui.cancelButton = CreateButton(list, 80, "Cancel", function() LoadForm() end)
    ui.cancelButton:SetPoint("LEFT", ui.addButton, "RIGHT", 6, 0)
    ui.copyButton = CreateButton(list, 100, "Copy as new", function()
        form.editing = nil
        ui.nameBox:SetText("")
        RefreshUI()
    end)
    ui.copyButton:SetPoint("LEFT", ui.cancelButton, "RIGHT", 6, 0)

    CreateRule(list):SetPoint("TOPLEFT", 20, -34)
    CreateText(list, "GameFontNormal", "Your macros"):SetPoint("TOPLEFT", 20, -44)
    ui.slotCount = CreateText(list, "GameFontHighlightSmall")
    ui.slotCount:SetPoint("TOPRIGHT", -20, -47)
    ui.macrosEmpty = CreateText(list, "GameFontDisableSmall",
        "None yet. Pick a template, fill each slot, then click Create macro.")
    ui.macrosEmpty:SetPoint("TOPLEFT", 20, -(LIST_OFFSET + 6))
end

local function LoadTemplate(id)
    local template = id and iscMacroTemplates.list[id]
    ui.templateEditing = id
    ui.templateName:SetText(template and template.name or "")
    ui.templateBox:SetText(template and template.text or "")
    ui.templateName:ClearFocus()
    ui.templateBox:ClearFocus()
    RefreshUI()
end

local function UpdateTemplateInfo()
    local text = strtrim(ui.templateBox:GetText())
    local keys = Placeholders(text)
    if #keys == 0 then
        ui.templateSlots:SetText("|cff808080No slots yet.|r")
    elseif #keys > MAX_SLOTS then
        ui.templateSlots:SetText(("|cffff4040%d slots, max %d|r"):format(#keys, MAX_SLOTS))
    else
        ui.templateSlots:SetText("|cff808080Slots: " .. table.concat(keys, ", ") .. "|r")
    end

    local longest
    for _, macro in pairs(iscMacroDB.macros) do
        if macro.template == ui.templateEditing then
            local body = BuildBody(macro, text)
            if body then longest = math.max(longest or 0, #body) end
        end
    end
    ui.templateLength:SetShown(longest ~= nil)
    if longest then
        local color = longest > MAX_BODY and "|cffff4040" or "|cff808080"
        ui.templateLength:SetText(("%sLongest macro: %d / %d|r"):format(color, longest, MAX_BODY))
    end
end

local function GetTemplateRow(i)
    if templateRows[i] then return templateRows[i] end

    local row = CreateListRow(ui.templatesPage, TEMPLATE_ROW_HEIGHT - 2, function(self)
        local name = iscMacroTemplates.list[self.id].name
        local uses = TemplateUseCount(self.id)
        if uses > 0 then
            Print(("'%s' is still used by %d of this character's macros. Delete them or switch them to another template first.")
                :format(name, uses))
        else
            StaticPopup_Show("ISCMACRO_DELETE_TEMPLATE", name, nil, self.id)
        end
    end)
    row:SetScript("OnClick", function(self) LoadTemplate(self.id) end)

    row.title:SetPoint("LEFT", 6, 0)
    row.title:SetPoint("RIGHT", row.sub, "LEFT", -8, 0)

    templateRows[i] = row
    return row
end

local function RefreshTemplates()
    local ids = SortedTemplateIds()
    for i, id in ipairs(ids) do
        local row = GetTemplateRow(i)
        row.id = id
        row:SetPoint("TOPLEFT", 20, -(32 + (i - 1) * TEMPLATE_ROW_HEIGHT))
        row.title:SetText(iscMacroTemplates.list[id].name)
        local uses = TemplateUseCount(id)
        row.sub:SetText(uses == 1 and "1 macro" or ("%d macros"):format(uses))
        row.selected:SetShown(id == ui.templateEditing)
        row:Show()
    end
    for i = #ids + 1, #templateRows do templateRows[i]:Hide() end
    ui.templatesEmpty:SetShown(#ids == 0)

    local editing = ui.templateEditing and iscMacroTemplates.list[ui.templateEditing]
    ui.editorTitle:SetText(editing and ("Editing '%s'"):format(editing.name) or "New template")
    local editorTop = 32 + math.max(#ids, 1) * TEMPLATE_ROW_HEIGHT + 8
    ui.templateEditor:SetPoint("TOPLEFT", 0, -editorTop)
    ui.templatesPage:SetHeight(editorTop + EDITOR_HEIGHT)
end

local function CreateTemplatesPage()
    local page = CreatePage()
    ui.templatesPage = page

    CreateText(page, "GameFontNormal", "Templates"):SetPoint("TOPLEFT", 20, -8)
    local new = CreateButton(page, 110, "New template", function()
        LoadTemplate(nil)
        ui.templateName:SetFocus()
    end)
    new:SetPoint("TOPRIGHT", -20, -4)

    ui.templatesEmpty = CreateText(page, "GameFontDisableSmall", "No templates yet. Write one below.")
    ui.templatesEmpty:SetPoint("TOPLEFT", 20, -38)

    local editor = CreateFrame("Frame", nil, page)
    editor:SetSize(WIDTH, EDITOR_HEIGHT)
    ui.templateEditor = editor

    CreateRule(editor):SetPoint("TOPLEFT", 20, 0)
    ui.editorTitle = CreateText(editor, "GameFontNormal")
    ui.editorTitle:SetPoint("TOPLEFT", 20, -10)

    local nameLabel = CreateText(editor, "GameFontHighlightSmall", "Name")
    nameLabel:SetPoint("TOPLEFT", 20, -40)
    ui.templateName = CreateInputBox(editor, 200, 32)
    ui.templateName:SetPoint("LEFT", nameLabel, "LEFT", 62, 0)

    local legend = CreateText(editor, "GameFontDisableSmall",
        "Write {name} where a spell or item goes. Each different {name} is one slot.")
    legend:SetPoint("TOPLEFT", 20, -64)

    local boxBg = CreateFrame("Frame", nil, editor)
    boxBg:SetSize(INNER_WIDTH, 90)
    boxBg:SetPoint("TOPLEFT", 20, -80)
    local bg = boxBg:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.6)

    ui.templateBox = CreateFrame("EditBox", nil, boxBg)
    ui.templateBox:SetPoint("TOPLEFT", 6, -6)
    ui.templateBox:SetPoint("BOTTOMRIGHT", -6, 6)
    ui.templateBox:SetMultiLine(true)
    ui.templateBox:SetAutoFocus(false)
    ui.templateBox:SetFontObject(GameFontHighlightSmall)
    ui.templateBox:SetScript("OnEscapePressed", ui.templateBox.ClearFocus)
    ui.templateBox:SetScript("OnTextChanged", UpdateTemplateInfo)

    ui.templateSlots = CreateText(editor, "GameFontHighlightSmall")
    ui.templateSlots:SetPoint("TOPLEFT", 20, -176)
    ui.templateSlots:SetWidth(250)
    ui.templateSlots:SetJustifyH("LEFT")
    ui.templateSlots:SetWordWrap(false)
    ui.templateLength = CreateText(editor, "GameFontHighlightSmall")
    ui.templateLength:SetPoint("TOPRIGHT", -20, -176)

    local save = CreateButton(editor, 120, "Save template", function()
        ui.templateBox:ClearFocus()
        local id = SaveTemplate(ui.templateEditing, ui.templateName:GetText(), ui.templateBox:GetText())
        if id then LoadTemplate(id) end
    end)
    save:SetPoint("TOPLEFT", 20, -194)
    local cancel = CreateButton(editor, 80, "Cancel", function() LoadTemplate(nil) end)
    cancel:SetPoint("LEFT", save, "RIGHT", 6, 0)
end

DefineConfirm("ISCMACRO_DELETE_MACRO",
    "Delete the macro '%s'? It will also disappear from your action bars.",
    function(name)
        if form.editing == name then LoadForm() end
        RemoveMacro(name)
    end)

DefineConfirm("ISCMACRO_DELETE_TEMPLATE",
    "Delete the template '%s'? Macros on your other characters that use it will stop updating.",
    function(id)
        if ui.templateEditing == id then LoadTemplate(nil) end
        iscMacroTemplates.list[id] = nil
        RefreshUI()
    end)

RefreshUI = function()
    if not ui then return end
    RefreshMacros()
    RefreshTemplates()
    local page = ui.page == "templates" and ui.templatesPage or ui.macrosPage
    ui:SetHeight(PAGE_TOP + page:GetHeight() + 14)
end

local function ShowPage(page)
    ui.page = page
    ui.macrosPage:SetShown(page == "macros")
    ui.templatesPage:SetShown(page == "templates")
    for _, tab in ipairs({ ui.macrosTab, ui.templatesTab }) do
        local selected = tab.page == page
        tab:SetNormalFontObject(selected and GameFontHighlight or GameFontDisable)
        tab.underline:SetShown(selected)
    end
    RefreshUI()
end

local function CreateTab(text, page)
    local tab = CreateFrame("Button", nil, ui)
    tab:SetSize(100, 24)
    tab.page = page
    tab:SetNormalFontObject(GameFontDisable)
    tab:SetText(text)
    tab:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    tab.underline = tab:CreateTexture(nil, "ARTWORK")
    tab.underline:SetColorTexture(1, 0.82, 0, 1)
    tab.underline:SetHeight(2)
    tab.underline:SetPoint("BOTTOMLEFT")
    tab.underline:SetPoint("BOTTOMRIGHT")
    tab:SetScript("OnClick", function() ShowPage(page) end)
    return tab
end

local function CreateUI()
    ui = CreateFrame("Frame", "iscMacroFrame", UIParent, "BasicFrameTemplateWithInset")
    ui:SetWidth(WIDTH)
    ui:SetPoint("CENTER")
    ui:SetFrameStrata("DIALOG")
    ui:SetMovable(true)
    ui:EnableMouse(true)
    ui:RegisterForDrag("LeftButton")
    ui:SetScript("OnDragStart", ui.StartMoving)
    ui:SetScript("OnDragStop", ui.StopMovingOrSizing)
    ui:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "iscMacroFrame") -- close with Escape

    ui.TitleText:SetText("iscMacro")
    -- Defines MAX_CHARACTER_MACROS for the slot counter.
    C_AddOns.LoadAddOn("Blizzard_MacroUI")

    ui.macrosTab = CreateTab("Macros", "macros")
    ui.macrosTab:SetPoint("TOPLEFT", 20, -28)
    ui.templatesTab = CreateTab("Templates", "templates")
    ui.templatesTab:SetPoint("LEFT", ui.macrosTab, "RIGHT", 4, 0)
    CreateRule(ui):SetPoint("TOPLEFT", 20, -52)

    CreateMacrosPage()
    CreateTemplatesPage()
    LoadTemplate(nil)
    LoadForm(nil)
    ShowPage("macros")
    ui:Hide()
end

local function ToggleUI()
    if not ui then CreateUI() end
    if ui:IsShown() then
        ui:Hide()
    else
        RefreshUI()
        ui:Show()
    end
end

-- Assumes the default round minimap.
local function PlaceMinimapButton(button)
    local angle = math.rad(iscMacroDB.minimapAngle or 225)
    local radius = Minimap:GetWidth() / 2 + 5
    button:SetPoint("CENTER", Minimap, "CENTER", radius * math.cos(angle), radius * math.sin(angle))
end

local function FollowCursor(button)
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    iscMacroDB.minimapAngle = math.deg(math.atan2(py / scale - my, px / scale - mx)) % 360
    PlaceMinimapButton(button)
end

local function CreateMinimapButton()
    -- Button collectors such as MinimapButtonButton only pick up named frames like this one.
    local button = CreateFrame("Button", "iscMacroMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetSize(20, 20)
    background:SetPoint("TOPLEFT", 7, -5)
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Note_01")
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -6)
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")

    button:RegisterForClicks("LeftButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetScript("OnClick", ToggleUI)
    button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", FollowCursor) end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    button:SetScript("OnEnter", function(self) SimpleTooltip(self, "iscMacro\nClick to open.") end)
    button:SetScript("OnLeave", GameTooltip_Hide)
    PlaceMinimapButton(button)
end

SLASH_ISCMACRO1 = "/iscmacro"
SLASH_ISCMACRO2 = "/isc"
SlashCmdList.ISCMACRO = ToggleUI

-- Each default is offered once, so one the player deleted or renamed doesn't come back.
local function AddDefaultTemplates()
    local templates = iscMacroTemplates
    templates.offered = templates.offered or {}
    local names = {}
    for _, template in pairs(templates.list) do names[template.name] = true end
    for _, default in ipairs(DEFAULT_TEMPLATES) do
        if not templates.offered[default.name] and not names[default.name] then
            templates.list[templates.nextId] = { name = default.name, text = default.text }
            templates.nextId = templates.nextId + 1
        end
        templates.offered[default.name] = true
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        iscMacroTemplates = iscMacroTemplates or { nextId = 1, list = {} }
        AddDefaultTemplates()
        iscMacroDB = iscMacroDB or { macros = {} }
        -- Button collectors only scan shortly after login.
        CreateMinimapButton()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Nothing that feeds the macros changes between loading screens; login and /reload sync.
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        Sync()
    elseif event == "PLAYER_REGEN_ENABLED" and pendingSync then
        Sync()
    end
end)
