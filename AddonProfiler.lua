local AP = {}
local ROW_HEIGHT = 20
local MAX_ROWS = 12
local sortKey, sortOrder = "totalCPU", true
local addonList, profileData, hasModules, expandedAddons = {}, {}, {}, {}
local timeElapsed, profileEndTime, cpuProfiling, profilerInterrupted = 0
local profileFrame = CreateFrame("Frame")
profileFrame:Hide()

AddonProfiler = AP

local L = {
	["Start"] = "Start",
	["Stop"] = "Stop",
	["Let's you filter out addons that should not be included in the profiling, not required."] = "Let's you filter out addons that should not be included in the profiling, not required.",
	["Addon filter"] = "Addon filter",
	["Profile duration (seconds)"] = "Profile duration (seconds)",
	["Include modules"] = "Include modules",
	["%d seconds left"] = "%d seconds left",
	["Speedy polling"] = "Speedy polling",
	["Enable CPU profiling"] = "Enable CPU profiling",
	["Any addons that have another addon listed as a single dependency will have their memory and CPU stats merged into their parents addon."] = "Any addons that have another addon listed as a single dependency will have their memory and CPU stats merged into their parents addon.",
	["Enables CPU profiling, you will need to do a /console reloadui for this to be enabled."] = "Enables CPU profiling, you will need to do a /console reloadui for this to be enabled.",
	["This will poll for garbage created every frame update, this will make the garbage collected numbers more accurate but it uses more CPU during an active profile."] = "This will poll for garbage created every frame update, this will make the garbage collected numbers more accurate but it uses more CPU during an active profile.",
	["Finished profiling"] = "Finished profiling",
	["Profiler interrupted"] = "Profiler interrupted",
	["How long the profiler should run, you have to set a number in seconds."] = "How long the profiler should run, you have to set a number in seconds.",
	["CPU"] = "CPU",
	["CPU/Sec"] = "CPU/Sec",
	["Avg/Sec"] = "Avg/Sec",
	["Memory"] = "Memory",
	["Garbage"] = "Garbage",
}

local memory
local function profileMemory()
	-- We're done profiling, so force a full garbage collection to get the total GC
	if( GetTime() <= profileEndTime ) then
		collectgarbage("collect")
	end

	UpdateAddOnMemoryUsage()
	for _, id in pairs(addonList) do
		memory = GetAddOnMemoryUsage(id)
		
		-- Memory was reduced, meaning garbage was created.
		if( memory <= profileData[id].totalMemory ) then
			profileData[id].garbage = profileData[id].garbage + (profileData[id].totalMemory - memory)
		end
		
		profileData[id].totalMemory = memory
	end
end

local cpu, cpuDiff
local function profileCPU()
	UpdateAddOnCPUUsage()
	for _, id in pairs(addonList) do
		cpu = GetAddOnCPUUsage(id)
		cpuDiff = cpu - profileData[id].totalCPU
		
		profileData[id].cpuSecond = cpuDiff
		profileData[id].cpuAverage = profileData[id].cpuAverage + cpuDiff
		profileData[id].cpuChecks = profileData[id].cpuChecks + 1
		profileData[id].totalCPU = cpu
	end
end

local function slowPoll(self, elapsed)
	timeElapsed = timeElapsed + elapsed
	if( timeElapsed >= 1 ) then
		timeElapsed = 0
		
		profileMemory()
		profileCPU()
	
		AP:UpdateFrame()
	end
end

local function fastPoll(self, elapsed)
	profileMemory()
	
	timeElapsed = timeElapsed + elapsed
	if( timeElapsed >= 1 ) then
		timeElapsed = 0
		
		profileCPU()
		AP:UpdateFrame()
	end
end

local function startProfiling()
	AP.selectFrame.start:SetText(L["Stop"])
	AP.selectFrame.start.isStarted = true
	
	-- Figure out when profiling is over
	profilerInterrupted = false
	profileEndTime = GetTime() + AP.db.duration

	-- Reset stats
	ResetCPUUsage()
	collectgarbage("collect")
	
	timeElapsed = 0
	
	-- Update and grab initial info and lets go
	UpdateAddOnMemoryUsage()
	UpdateAddOnCPUUsage()
	
	-- Load initial profiling data
	for k in pairs(addonList) do addonList[k] = nil end
	for k in pairs(hasModules) do hasModules[k] = nil end
	for id=1, GetNumAddOns() do
		if( IsAddOnLoaded(id) ) then
			local name = GetAddOnInfo(id)
			if( not AP.db.filter or AP.db.filter == "" or string.match(name, AP.db.filter) ) then
				local requiredDep, hasSecond = GetAddOnDependencies(id)
				local parent = not hasSecond and requiredDep
				
				profileData[name] = profileData[name] or {}
				profileData[name].totalCPU = GetAddOnCPUUsage(id)
				profileData[name].totalMemory = GetAddOnMemoryUsage(id)
				profileData[name].cpuSecond = 0
				profileData[name].cpuAverage = 0
				profileData[name].cpuChecks = 0
				profileData[name].garbage = 0
				profileData[name].parent = parent
				
				-- Indicates that when we display the parents addon, we need to find it's children too
				if( parent and AP.db.includeModules ) then
					hasModules[parent] = true
				end
				
				table.insert(addonList, name)
			end
		end
	end
	
	-- Update with the initial data
	AP.infoFrame.garbage:Show()
	AP.infoFrame.totalMemory:Show()
	AP.infoFrame.cpuSecond:Show()
	AP.infoFrame.totalCPU:Show()
	AP:UpdateFrame()

	-- Start the frame
	profileFrame:SetScript("OnUpdate", AP.db.quickPoll and fastPoll or slowPoll)
	profileFrame:Show()
end

local function stopProfiling()
	AP.selectFrame.start.isStarted = nil
	AP.selectFrame.start:SetText(L["Start"])
	profileFrame:Hide()

	AP:UpdateFrame()
end

local function sortAddons(a, b)
	if( profileData[a][sortKey] == profileData[b][sortKey] ) then
		return a < b
	elseif( not sortOrder ) then
		return profileData[a][sortKey] < profileData[b][sortKey]
	end

	return profileData[a][sortKey] > profileData[b][sortKey]
end

local rowList = {}
function AP:UpdateFrame()
	if( not AP.frame:IsVisible() ) then return end
	
	-- Build the table for displaying rows
	for i=#(rowList), 1, -1 do table.remove(rowList, i) end
	
	table.sort(addonList, sortAddons)
	for _, name in pairs(addonList) do
		if( not AP.db.includeModules or not profileData[name].parent ) then
			table.insert(rowList, name)
			
			if( hasModules[name] and expandedAddons[name] ) then
				for _, subName in pairs(addonList) do
					if( profileData[subName].parent == name ) then
						table.insert(rowList, subName)
					end
				end
			end
		end
	end
	
	-- Check if we're done with profiling
	local profiling
	if( profilerInterrupted or profileEndTime <= GetTime() ) then
		if( not profilerInterrupted and AP.selectFrame.start.isStarted ) then
			stopProfiling()
		end
		AP.infoFrame.time:SetText(profilerInterrupted and L["PRofiler interrupted"] or L["Finished profiling"])
		AP.infoFrame.cpuSecond:SetText(L["Avg/Sec"])
	else
		profiling = true
		AP.infoFrame.time:SetFormattedText(L["%d seconds left"], profileEndTime - GetTime())
		AP.infoFrame.cpuSecond:SetText(L["CPU/Sec"])
	end

	-- Now actually display it
	FauxScrollFrame_Update(AP.frame.scroll, #(rowList), MAX_ROWS - 1, ROW_HEIGHT)
	local offset = FauxScrollFrame_GetOffset(AP.frame.scroll)
	local rowID = 1
	
	for _, row in pairs(AP.rows) do
		row:Hide()
	end
	
	for id, name in pairs(rowList) do
		if( id >= offset and AP.rows[rowID] ) then
			-- Set addon title
			local title = select(2, GetAddOnInfo(name))
			local row = AP.rows[rowID]
			row.tooltip = title
			row.addonName = name
			row:Show()

			if( hasModules[name] and expandedAddons[name] ) then
				row:SetFormattedText("[|cffff1919-|r] %s", title)
			elseif( hasModules[name] ) then
				row:SetFormattedText("[|cff19ff19+|r] %s", title)
			elseif( AP.db.includeModules and profileData[name].parent ) then
				row:SetFormattedText("    %s", title)
			else
				row:SetText(title)
			end
			
			local totalCPU, cpuSecond, cpuAverage, cpuChecks, totalMemory, garbage = profileData[name].totalCPU, profileData[name].cpuSecond, profileData[name].cpuAverage, profileData[name].cpuChecks, profileData[name].totalMemory, profileData[name].garbage
			-- Grab all of the modules settings
			if( hasModules[name] ) then
				for _, data in pairs(profileData) do
					if( data.parent == name ) then
						totalCPU = totalCPU + data.totalCPU
						cpuSecond = cpuSecond + data.cpuSecond
						cpuAverage = cpuAverage + data.cpuAverage
						cpuChecks = cpuChecks + data.cpuChecks
						totalMemory = totalMemory + data.totalMemory
						garbage = garbage + data.garbage
					end
				end
			end
			
			-- Set CPU stats if they're enabled
			if( cpuProfiling ) then
				row.totalCPU:SetFormattedText("%.1f", totalCPU)
				row.cpu:SetFormattedText("%.1f", profiling and cpuSecond or (cpuAverage / cpuChecks))
			end
			
			-- Set memory stats
			if( totalMemory > 1024 ) then
				row.totalMemory:SetFormattedText("%.1f %s", totalMemory / 1024, "MiB")
			else
				row.totalMemory:SetFormattedText("%.1f %s", totalMemory, "KiB")
			end

			if( garbage > 1024 ) then
				row.garbage:SetFormattedText("%.1f %s", garbage / 1024, "MiB")
			else
				row.garbage:SetFormattedText("%.1f %s", garbage, "KiB")
			end

			rowID = rowID + 1
		end
	end
end

function AP:CreateFrame()
	if( self.frame ) then return end
	local backdrop = {
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\ChatFrame\\ChatFrameBackground",
		edgeSize = 1,
		insets = {left = 1, right = 1, top = 1, bottom = 1}}
	
	-- Main profiling frame
	self.frame = CreateFrame("Frame", "APFrame", UIParent)
	self.frame:SetBackdrop(backdrop)
	self.frame:SetBackdropColor(0, 0, 0, 0.90)
	self.frame:SetBackdropBorderColor(0.75, 0.75, 0.75, 1)
	self.frame:SetHeight(270)
	self.frame:SetWidth(425)
	self.frame:ClearAllPoints()
	self.frame:SetPoint("CENTER", UIParent, "CENTER", 150, 150)
	self.frame:SetMovable(true)
	self.frame:SetScript("OnShow", function()
		if( profileEndTime ) then
			AP:UpdateFrame()
		end
	end)
	self.frame:Hide()

	table.insert(UISpecialFrames, "APFrame")
	
	self.frame.scroll = CreateFrame("ScrollFrame", "APFrameScroll", self.frame, "FauxScrollFrameTemplate")
	self.frame.scroll:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, -4)
	self.frame.scroll:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -26, 3)
	self.frame.scroll:SetScript("OnVerticalScroll", function(self, value) FauxScrollFrame_OnVerticalScroll(self, value, ROW_HEIGHT, AP.UpdateFrame) end)
	
	local function showTooltip(self)
		if( self.tooltip ) then
			GameTooltip:SetOwner(self, "ANCHOR_LEFT")
			GameTooltip:SetText(self.tooltip, nil, nil, nil, nil, 1)
		end
	end
		
	local function hideTooltip(self)
		GameTooltip:Hide()
	end
	
	local function toggleParent(self)
		expandedAddons[self.addonName] = not expandedAddons[self.addonName]
		AP:UpdateFrame()
	end

	-- Create rows for addons
	self.rows = {}
		
	for id=1, MAX_ROWS do
		local row = CreateFrame("Button", nil, self.frame)
		row:SetWidth(415)
		row:SetHeight(ROW_HEIGHT)
		row:SetNormalFontObject(GameFontHighlightSmall)
		row:SetText("<name>")
		row:GetFontString():SetPoint("LEFT", row, "LEFT", 0, 0)
		row:GetFontString():SetJustifyH("LEFT")
		row:GetFontString():SetJustifyV("CENTER")
		row:SetPushedTextOffset(0, 0)
		row:SetScript("OnEnter", showTooltip)
		row:SetScript("OnLeave", hideTooltip)
		row:SetScript("OnClick", toggleParent)
		row:GetFontString():SetWidth(135)
		row:GetFontString():SetHeight(20)
		row:Hide()
		
		row.totalCPU = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		row.totalCPU:SetPoint("TOPLEFT", row, "TOPLEFT", 150, -6)
		row.totalCPU:SetText("---")
		
		row.cpu = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		row.cpu:SetPoint("TOPLEFT", row.totalCPU, "TOPLEFT", 55, 0)
		row.cpu:SetText("---")
		
		row.totalMemory = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		row.totalMemory:SetPoint("TOPLEFT", row.cpu, "TOPLEFT", 55, 0)
		
		row.garbage = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		row.garbage:SetPoint("TOPLEFT", row.totalMemory, "TOPLEFT", 70, 0)
		
		if( id > 1 ) then
			row:SetPoint("TOPLEFT", self.rows[id - 1], "BOTTOMLEFT", 0, -2)
		else
			row:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 4, -1)
		end
		
		self.rows[id] = row
	end
	
	-- Info frame above the main profiling frame
	self.infoFrame = CreateFrame("Frame", nil, self.frame)
	self.infoFrame:SetBackdrop(backdrop)
	self.infoFrame:SetBackdropColor(0, 0, 0, 0.90)
	self.infoFrame:SetBackdropBorderColor(0.75, 0.75, 0.75, 1)
	self.infoFrame:SetHeight(20)
	self.infoFrame:SetWidth(self.frame:GetWidth())
	self.infoFrame:ClearAllPoints()
	self.infoFrame:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, 25)

	self.infoFrame.time = self.infoFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	self.infoFrame.time:SetPoint("TOPLEFT", self.infoFrame, "TOPLEFT", 3, -4)
	self.infoFrame.time:SetWidth(130)
	self.infoFrame.time:SetHeight(self.infoFrame:GetHeight())
	self.infoFrame.time:SetJustifyH("LEFT")
	self.infoFrame.time:SetJustifyV("TOP")

	-- Create the header category things
	local function changeSorting(self)
		if( sortKey ~= self.sortKey ) then
			sortOrder = true
		else
			sortOrder = not sortOrder
		end
		
		sortKey = self.sortKey
		AP:UpdateFrame()
	end
	
	local totalCPU = self.infoFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	totalCPU:SetText(L["CPU"])
	totalCPU:SetPoint("TOPLEFT", self.rows[1].totalCPU, "TOPLEFT", 0, 28)
	totalCPU:Hide()
	
	totalCPU.sort = CreateFrame("Button", nil, self.infoFrame)
	totalCPU.sort:SetAllPoints(totalCPU)
	totalCPU.sort.sortKey = "totalCPU"
	totalCPU.sort:SetScript("OnClick", changeSorting)
	
	self.infoFrame.totalCPU = totalCPU

	local cpuSecond = self.infoFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	cpuSecond:SetText(L["CPU/Sec"])
	cpuSecond:SetPoint("TOPLEFT", self.rows[1].cpu, "TOPLEFT", 0, 28)
	cpuSecond:Hide()

	cpuSecond.sort = CreateFrame("Button", nil, self.infoFrame)
	cpuSecond.sort:SetAllPoints(cpuSecond)
	cpuSecond.sort.sortKey = "cpuSecond"
	cpuSecond.sort:SetScript("OnClick", changeSorting)
	
	self.infoFrame.cpuSecond = cpuSecond

	local totalMemory = self.infoFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	totalMemory:SetText(L["Memory"])
	totalMemory:SetPoint("TOPLEFT", self.rows[1].totalMemory, "TOPLEFT", 0, 28)
	totalMemory:Hide()

	totalMemory.sort = CreateFrame("Button", nil, self.infoFrame)
	totalMemory.sort:SetAllPoints(totalMemory)
	totalMemory.sort.sortKey = "totalMemory"
	totalMemory.sort:SetScript("OnClick", changeSorting)

	self.infoFrame.totalMemory = totalMemory

	local garbage = self.infoFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	garbage:SetText(L["Garbage"])
	garbage:SetPoint("TOPLEFT", self.rows[1].garbage, "TOPLEFT", 0, 28)
	garbage:Hide()

	garbage.sort = CreateFrame("Button", nil, self.infoFrame)
	garbage.sort:SetAllPoints(garbage)
	garbage.sort.sortKey = "garbage"
	garbage.sort:SetScript("OnClick", changeSorting)
	
	self.infoFrame.garbage = garbage
	
	-- Can't forget the button to make it movable
	local mover = CreateFrame("Frame", nil, self.infoFrame)
	mover:SetAllPoints(self.infoFrame)
	mover:SetMovable(true)
	mover:EnableMouse(true)
	mover:RegisterForDrag("LeftButton")
	mover:SetScript("OnDragStart", function(self)
		AP.frame:StartMoving()
	end)
	mover:SetScript("OnDragStop", function(self)
		AP.frame:StopMovingOrSizing()
	end)
	
	-- Close button
	local button = CreateFrame("Button", nil, mover, "UIPanelCloseButton")
	button:SetPoint("TOPRIGHT", 6, 6)
	button:SetScript("OnClick", function()
		HideUIPanel(AP.frame)
	end)
	
	self.infoFrame.closeButton = button
	
	-- Adding things to be profiled/general settings
	self.selectFrame = CreateFrame("Frame", nil, self.frame)
	self.selectFrame:SetBackdrop(backdrop)
	self.selectFrame:SetBackdropColor(0, 0, 0, 0.90)
	self.selectFrame:SetBackdropBorderColor(0.75, 0.75, 0.75, 1)
	self.selectFrame:SetHeight(295)
	self.selectFrame:SetWidth(155)
	self.selectFrame:ClearAllPoints()
	self.selectFrame:SetPoint("TOPRIGHT", self.frame, "TOPLEFT", -5, 25)
	self.selectFrame:SetScript("OnShow", function(self)
		self.quick:SetChecked(AP.db.quickPoll)
		self.modules:SetChecked(AP.db.includeModules)
		self.duration:SetNumber(AP.db.duration or 0)
		self.filter:SetText(AP.db.filter or "")
		self.cpu:SetChecked(GetCVarBool("scriptProfile"))
	end)
	
	self.selectFrame.filter = CreateFrame("EditBox", "AddOnProfilerFilter", self.selectFrame, "InputBoxTemplate")
	self.selectFrame.filter:SetHeight(20)
	self.selectFrame.filter:SetWidth(144)
	self.selectFrame.filter:SetAutoFocus(false)
	self.selectFrame.filter:ClearAllPoints()
	self.selectFrame.filter:SetPoint("TOPLEFT", self.selectFrame, "TOPLEFT", 8, -18)
	self.selectFrame.filter.tooltip = L["Let's you filter out addons that should not be included in the profiling, not required."]
	self.selectFrame.filter:SetScript("OnEnter", showTooltip)
	self.selectFrame.filter:SetScript("OnLeave", hideTooltip)
	self.selectFrame.filter:SetScript("OnTextChanged", function(self)
		AP.db.filter = string.trim(self:GetText()) or ""
	end)

	self.selectFrame.filter.text = self.selectFrame.filter:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	self.selectFrame.filter.text:SetText(L["Addon filter"])
	self.selectFrame.filter.text:SetPoint("TOPLEFT", self.selectFrame.filter, "TOPLEFT", -4, 14)

	self.selectFrame.duration = CreateFrame("EditBox", "AddOnProfilerTime", self.selectFrame, "InputBoxTemplate")
	self.selectFrame.duration:SetHeight(20)
	self.selectFrame.duration:SetWidth(102)
	self.selectFrame.duration:SetAutoFocus(false)
	self.selectFrame.duration:SetNumeric(true)
	self.selectFrame.duration:ClearAllPoints()
	self.selectFrame.duration:SetPoint("TOPLEFT", self.selectFrame.filter, "BOTTOMLEFT", 0, -18)
	self.selectFrame.duration.tooltip = L["How long the profiler should run, you have to set a number in seconds."]
	self.selectFrame.duration:SetScript("OnEnter", showTooltip)
	self.selectFrame.duration:SetScript("OnLeave", hideTooltip)
	self.selectFrame.duration:SetScript("OnTextChanged", function(self)
		AP.db.duration = self:GetNumber() or 0
	end)

	self.selectFrame.duration.text = self.selectFrame.duration:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	self.selectFrame.duration.text:SetText(L["Profile duration (seconds)"])
	self.selectFrame.duration.text:SetPoint("TOPLEFT", self.selectFrame.duration, "TOPLEFT", -4, 14)

	self.selectFrame.start = CreateFrame("Button", nil, self.selectFrame, "UIPanelButtonGrayTemplate")
	self.selectFrame.start:SetText(L["Start"])
	self.selectFrame.start:SetHeight(21)
	self.selectFrame.start:SetWidth(38)
	self.selectFrame.start:SetPoint("TOPLEFT", self.selectFrame.duration, "TOPRIGHT", 0, 0)
	self.selectFrame.start:SetScript("OnClick", function(self)
		if( self.isStarted ) then
			profilerInterrupted = true
			stopProfiling()
		else
			startProfiling()
		end
	end)
	
	self.selectFrame.modules = CreateFrame("CheckButton", nil, self.selectFrame, "OptionsCheckButtonTemplate")
	self.selectFrame.modules:SetHeight(18)
	self.selectFrame.modules:SetWidth(18)
	self.selectFrame.modules:SetChecked(true)
	self.selectFrame.modules:SetScript("OnEnter", showTooltip)
	self.selectFrame.modules:SetScript("OnLeave", hideTooltip)
	self.selectFrame.modules:SetScript("OnClick", function(self)
		AP.db.includeModules = self:GetChecked() and true or false
	end)
	self.selectFrame.modules.tooltip = L["Any addons that have another addon listed as a single dependency will have their memory and CPU stats merged into their parents addon."]
	self.selectFrame.modules:SetPoint("TOPLEFT", self.selectFrame.duration, "BOTTOMLEFT", -5, -5)
	self.selectFrame.modules.text = self.selectFrame.modules:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	self.selectFrame.modules.text:SetText(L["Include modules"])
	self.selectFrame.modules.text:SetPoint("TOPLEFT", self.selectFrame.modules, "TOPRIGHT", -1, -3)

	self.selectFrame.quick = CreateFrame("CheckButton", nil, self.selectFrame, "OptionsCheckButtonTemplate")
	self.selectFrame.quick:SetHeight(18)
	self.selectFrame.quick:SetWidth(18)
	self.selectFrame.quick:SetChecked(true)
	self.selectFrame.quick:SetScript("OnEnter", showTooltip)
	self.selectFrame.quick:SetScript("OnLeave", hideTooltip)
	self.selectFrame.quick:SetScript("OnClick", function(self)
		AP.db.quickPoll = self:GetChecked() and true or false
	end)
	self.selectFrame.quick.tooltip = L["This will poll for garbage created every frame update, this will make the garbage collected numbers more accurate but it uses more CPU during an active profile."]
	self.selectFrame.quick:SetPoint("TOPLEFT", self.selectFrame.modules, "BOTTOMLEFT", 0, -5)
	self.selectFrame.quick.text = self.selectFrame.quick:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	self.selectFrame.quick.text:SetText(L["Speedy polling"])
	self.selectFrame.quick.text:SetPoint("TOPLEFT", self.selectFrame.quick, "TOPRIGHT", -1, -3)

	self.selectFrame.cpu = CreateFrame("CheckButton", nil, self.selectFrame, "OptionsCheckButtonTemplate")
	self.selectFrame.cpu:SetHeight(18)
	self.selectFrame.cpu:SetWidth(18)
	self.selectFrame.cpu:SetChecked(true)
	self.selectFrame.cpu:SetScript("OnEnter", showTooltip)
	self.selectFrame.cpu:SetScript("OnLeave", hideTooltip)
	self.selectFrame.cpu.tooltip = L["Enables CPU profiling, you will need to do a /console reloadui for this to be enabled."]
	self.selectFrame.cpu:SetScript("OnClick", function(self)
		SetCVar("scriptProfile", self:GetChecked() and "1" or "0")
	end)
	self.selectFrame.cpu:SetPoint("TOPLEFT", self.selectFrame.quick, "BOTTOMLEFT", 0, -5)
	self.selectFrame.cpu.text = self.selectFrame.cpu:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	self.selectFrame.cpu.text:SetText(L["Enable CPU profiling"])
	self.selectFrame.cpu.text:SetPoint("TOPLEFT", self.selectFrame.cpu, "TOPRIGHT", -1, -3)
end


SLASH_ADDONPROFILE1 = "/addonprofiler"
SLASH_ADDONPROFILE2 = "/addonprofile"
SLASH_ADDONPROFILE3 = "/ap"
SLASH_ADDONPROFILE4 = "/profile"
SlashCmdList["ADDONPROFILE"] = function(msg)
	AP:CreateFrame()
	
	if( AP.frame:IsVisible() ) then
		AP.frame:Hide()
	else
		AP.frame:Show()
	end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, event, addon)
	if( addon ~= "AddonProfiler" ) then return end
	self:UnregisterAllEvents()
	
	AddonProfilerDB = AddonProfilerDB or {includeModules = true, quickPoll = false, duration = 120}
	AP.db = AddonProfilerDB
	
	-- CPU profiling is not enabled until you do a UI reload, so we have to check it here to see if it's enabled
	cpuProfiling = GetCVarBool("scriptProfile")
end)
