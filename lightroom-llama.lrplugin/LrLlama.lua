-- TODOs
-- - Add support for multiple photos
-- - Add support for multiple models
-- - Provide the model more information for context: folder name, datetime, any existing keywords, maybe more GPS info
-- - PgUp/PgDn to navigate through photos

local LrHttp = import 'LrHttp'
local LrPathUtils = import 'LrPathUtils'
local LrLogger = import 'LrLogger'
local LrApplication = import "LrApplication"
local LrErrors = import "LrErrors"
local LrDialogs = import "LrDialogs"
local LrView = import "LrView"
local LrTasks = import "LrTasks"
local LrFunctionContext = import "LrFunctionContext"
local LrFileUtils = import 'LrFileUtils'
local LrStringUtils = import 'LrStringUtils'
local LrBinding = import "LrBinding"
local LrColor = import "LrColor"

local logger = LrLogger('LrOllamaTagger')
logger:enable("logfile") -- Logs to ~/Documents/LrClassicLogs | tail -f LrLlama.log

local model = "minicpm-v"

logger:info("Initializing Lightroom Ollama Tagger Plugin")

JSON = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "JSON.lua"))))()

local LrLlama = {}  -- Module table

local function exportThumbnail(photo)
    local tempPath = LrFileUtils.chooseUniqueFileName(LrPathUtils.getStandardFilePath('temp') .. "thumbnail.jpg")

    local success, result = photo:requestJpegThumbnail(512, 512, function(jpegData)
        -- Save the JPEG thumbnail to the temporary file
        if jpegData then
            local tempFile = io.open(tempPath, "wb")
            if tempFile then
                tempFile:write(jpegData)
                tempFile:close()
                logger:info("Thumbnail save requested to " .. tempPath)
                return true
            else
                logger:error("Failed to create temporary file at " .. tempPath)
            end
        else
            logger:error("Failed to get JPEG thumbnail data")
        end
        return false
    end)

    if success then
        logger:info("Thumbnail export requested")
        return tempPath
    else
        logger:warn("Failed to export thumbnail")
        return nil
    end
end

local function base64EncodeImage(imagePath)

    -- Read the image file as binary
    local file = io.open(imagePath, "rb") -- Open the file in binary mode
    if not file then
        LrDialogs.message("Error", "Could not open file: " .. imagePath, "critical")
        return
    end

    local binaryData = file:read("*all") -- Read the entire file as binary data
    file:close() -- Close the file

    -- Encode the binary data to Base64
    local base64Data = LrStringUtils.encodeBase64(binaryData)

    return base64Data
end


---@param photo LrPhoto The photo to send to the API
---@param prompt string The prompt to send to the API
---@param currentData table (optional) The current title, caption, and keywords of the photo
---@param currentKeywords string (optional) The current keywords to use
---@param useSystemPrompt boolean (optional) Whether to use the system prompt
---@return table response The response from the API
local function sendDataToApi(photo, prompt, currentData, currentKeywords, useSystemPrompt, location, folderName, date)
    logger:info("Sending data to API")
    local encodedImage = base64EncodeImage(exportThumbnail(photo))
    local url = "http://localhost:11434/api/generate"
    -- local currentKeywordString = type(currentKeywords) == "table" and table.concat(currentKeywords, ", ") or ""
    logger:info("currentKeywords: " .. currentKeywords)
    -- Define data to be sent (as a Lua table)
    local postData = {
        model = model,
        prompt = prompt,
        format = "json",
        system = [[You are an AI tasked with creating a JSON object containing a list of `keywords` based on a given piece of content (such as an image or video). ]] .. 
        [[You have been given the extra information which you can use for context. The information you've been given is: ]] ..
        [[ 1. The location, as the town or city, and the country: `]] .. location .. [[`. ]] ..
        [[ 2. The album name: `]] .. folderName .. [[`. ]] ..
        [[ 3. The date the photo was taken, if known: `]] .. date .. [[`. ]] ..
        [[ 4. The current keywords: `]] .. currentKeywords .. [[`. ]] ..
        [[Please follow these detailed guidelines for creating excellent metadata:

**Keywords:**
   - Provide a list of 7 to 50 keywords.
   - Keywords should be specific and directly related to the content.
   - Include broader topics, feelings, concepts, or associations represented by the content.
   - Avoid using unrelated terms or repeating words or compound words.
   - Do not include links, camera information, or trademarks unless required for editorial content.
   - Ensure keywords are in lowercase for consistency.
   - Consider the context provided by the folder name, location, and date (for example - the date might have a special meaning for holidays, events, or seasons, which should be localized to the country).
   - Do not include the date itself in the response.

### JSON Format:
```json
{
  "keywords": ["string"]
}
```

### Example:
```json
{
  "keywords": ["sunset", "beach", "calm", "ocean", "serene", "golden skies", "peaceful", "tranquil", "pastel colors", "horizon", "evening"]
}
```

Use this structure and guidelines to generate keywords that are descriptive, unique, and accurate.]]
,
        images = {encodedImage},
        stream = false
    }

    --logger:info("Post data: " .. JSON:encode(postData))

    -- Convert the Lua table to a JSON string
    local jsonPayload = JSON:encode(postData)

    -- Make a POST request
    local response, headers = LrHttp.post(url, jsonPayload, {{
        field = "Content-Type",
        value = "application/json"
    }})

    if response then
        local response_data = JSON:decode(response)
        local response_json = JSON:decode(response_data.response)
        return response_json
    else
        LrDialogs.message("Error", "Failed to send data to the API.", "critical")
        return "Error: Failed to send data to the API."
    end
end

local function main()
    -- Get the active catalog
    local catalog = LrApplication.activeCatalog()

    -- Get the selected photo
    local selectedPhotos = catalog:getTargetPhotos() -- Gets all selected photos
    if #selectedPhotos == 0 then
        LrDialogs.message("No photo selected", "Please select a photo to tag.", "critical")
        return
    end

    -- Get the first selected photo (if multiple, you can modify the code for more)
    local selectedPhoto = selectedPhotos[1]
    -- Export thumbnail and ensure it's ready before proceeding
    local thumbnailPath = nil
    LrTasks.startAsyncTask(function()
        thumbnailPath = exportThumbnail(selectedPhoto)
        logger:info("Thumbnail path: " .. thumbnailPath)
            -- Wait for thumbnail to be ready
        local attempts = 0
        while (not thumbnailPath or not LrFileUtils.exists(thumbnailPath)) and attempts < 100 do
            LrTasks.sleep(0.1)  -- Wait 100ms between checks
            attempts = attempts + 1
            if attempts % 10 == 0 then
                logger:info("Waiting for thumbnail, attempt: " .. attempts)
            end
        end
        if not thumbnailPath or not LrFileUtils.exists(thumbnailPath) then
            logger:error("Failed to create thumbnail")
            LrDialogs.message("Error", "Failed to create thumbnail for the photo.", "critical")
            return
        end
        logger:info("Thumbnail ready at: " .. thumbnailPath)

        if attempts >= 10 then
            logger:warn("Thumbnail took longer than expected to be ready")
            -- Update UI with yield
            LrTasks.yield()
            -- Trigger refresh by updating props
            LrLlama.updateProps({ status = "Thumbnail updated!" })
        end
        
    end)

    -- Wait for thumbnail to be ready
    local waitAttempts = 0
    while not thumbnailPath and waitAttempts < 10 do
        LrTasks.sleep(0.1)  -- Wait 100ms between checks
        waitAttempts = waitAttempts + 1
        logger:info("Waiting for thumbnail to be ready for UI, attempt: " .. waitAttempts)
    end
    
    if not thumbnailPath then
        logger:warn("Thumbnail not ready after maximum wait attempts")
    end
    
    logger:info("Thumbnail ready for UI at: " .. thumbnailPath)

    LrFunctionContext.callWithContext("showLlamaDialog", function(context)
        -- Create a property table for the UI
        local props = LrBinding.makePropertyTable(context)
        
        -- Create a function to update properties that can be called from elsewhere
        local function updateProps(newProps)
            for key, value in pairs(newProps) do
            props[key] = value
            end
        end
        LrLlama.updateProps = updateProps

        props.status = "Ready"
        props.statusColor = LrColor(0.149, 0.616, 0.412)
        props.prompt = "Tag this photo"
        props.keywords = selectedPhoto:getFormattedMetadata("keywordTags") or ""
        props.location = selectedPhoto:getFormattedMetadata("gps") or ""

        -- Parse GPS coordinates for reverse geolocation
        props.geoLocation = ""

        -- Function to parse GPS coordinates and call reverse geocoding API
        local function reverseGeocode(gpsString)
            -- Parse GPS string in format: "dd°mm'ss.ss" N/S dd°mm'ss.ss" E/W
            local lat_deg, lat_min, lat_sec, lat_dir, lon_deg, lon_min, lon_sec, lon_dir = 
                string.match(gpsString or "", "(%d+)°(%d+)'([%d%.]+)\" ([NS])[%s]+(%d+)°(%d+)'([%d%.]+)\" ([EW])")
            
            local lat, lon
            
            if lat_deg and lat_min and lat_sec and lat_dir and lon_deg and lon_min and lon_sec and lon_dir then
                -- Convert to decimal degrees
                lat = tonumber(lat_deg) + tonumber(lat_min)/60 + tonumber(lat_sec)/3600
                lon = tonumber(lon_deg) + tonumber(lon_min)/60 + tonumber(lon_sec)/3600
                
                -- Apply direction
                if lat_dir == "S" then lat = -lat end
                if lon_dir == "W" then lon = -lon end
                
                logger:info(string.format("Parsed GPS: %f, %f", lat, lon))
            else
                -- Fallback to original comma-separated format "xx.xxxx, yy.yyyy"
                lat, lon = string.match(gpsString or "", "([%d.-]+)[,%s]+([%d.-]+)")
            end
            
            if lat and lon then
                -- Construct the URL for Nominatim API
                local url = string.format(
                    "https://nominatim.openstreetmap.org/reverse?lat=%s&lon=%s&format=json",
                    lat, lon
                )
                
                -- Add required user agent header (Nominatim policy)
                local headers = {
                    { field = "User-Agent", value = "LightroomLlamaPlugin/1.0" }
                }
                
                -- Make the request
                local response, headers = LrHttp.get(url, headers)
                
                if response then
                    local result = JSON:decode(response)
                    local resultLocation = nil
                    if result and result.address then
                        if result.address.city and result.address.country then
                            resultLocation = result.address.city .. ", " .. result.address.country
                        elseif result.address.town and result.address.country then
                            resultLocation = result.address.town .. ", " .. result.address.country
                        elseif result.address.village and result.address.country then
                            resultLocation = result.address.village .. ", " .. result.address.country
                        elseif result.address.county and result.address.country then
                            resultLocation = result.address.county .. ", " .. result.address.country
                        elseif result.address.country then
                            resultLocation = result.address.country
                        end
                    end

                    if result and resultLocation then
                        props.geoLocation = string.lower(resultLocation)
                        logger:info("Reverse geocode result: " .. props.geoLocation)
                        return resultLocation
                    else
                        logger:warn("Invalid response from geocoding API")
                    end
                else
                    logger:warn("Failed to get response from geocoding API")
                end
            else
                logger:warn("Could not parse GPS coordinates: " .. (gpsString or "nil"))
            end
            
            return nil
        end

        local function keywordParser(keywords)
            keywords = keywords or {}
            local keywordList = {}
            if keywords then
                for keyword in string.gmatch(keywords, "[^,]+") do
                    local trimmedKeyword = LrStringUtils.trimWhitespace(keyword)
                    -- List of keywords to be filtered out
                    local keywordsToFilter = {
                        "privacy:ff",
                        "privacy:public",
                        "privacy:private",
                        "visibility:hidden"
                        -- Add more keywords to filter as needed
                    }
                    
                    local shouldInclude = true
                    for _, filterKeyword in ipairs(keywordsToFilter) do
                        if string.lower(trimmedKeyword) == string.lower(filterKeyword) then
                            shouldInclude = false
                            break
                        end
                    end
                    
                    if shouldInclude then
                        table.insert(keywordList, trimmedKeyword)
                    end
                end
                logger:info("Keywords found in current data: " .. table.concat(keywordList, ", "))
                return table.concat(keywordList, ", ")
            end
            logger:warn("No keywords found in current data")
            return ""
        end

        -- Call reverse geocoding when location is available
        if props.location and props.location ~= "" then
            LrTasks.startAsyncTask(function()
                props.status = "Looking up location..."
                props.statusColor = LrColor(0.4, 0.4, 0.7)
                props.geoLocation = reverseGeocode(props.location) or "Location not found"
                props.status = "Ready"
                props.statusColor = LrColor(0.149, 0.616, 0.412)
            end)
        end
        props.folderName = selectedPhoto:getFormattedMetadata("folderName") or ""
        props.date = ""
        -- Check if folderName starts with a date pattern (YYYYMMDD)
        local dateStr, remaining = string.match(props.folderName or "", "^(%d%d%d%d%d%d%d%d)%s*(.*)$")
        if dateStr then
            -- Format the plain YYYYMMDD string into a proper date format
            local year = string.sub(dateStr, 1, 4)
            local month = string.sub(dateStr, 5, 6)
            local day = string.sub(dateStr, 7, 8)
            props.date = year .. "-" .. month .. "-" .. day
            props.folderName = remaining or ""
            logger:info("Extracted date: " .. props.date .. " from folder name")
            logger:info("Remaining folder name: " .. props.folderName)
        end

        props.response = ""
        props.useSystemPrompt = true

        -- Create a view factory
        local f = LrView.osFactory()

        -- Define the dialog contents
        local c = f:view{
            bind_to_object = props,
            f:row{f:column{
                f:picture{
                    value = thumbnailPath,
                    frame_width = 2,
                    width = 400,
                    height = 400
                },
                width = 400
            }, f:spacer{
                width = 10
            }, f:column{
                f:static_text{
                    title = "Keywords:",
                    alignment = 'left'
                },
                f:spacer{f:label_spacing{}},
                f:edit_field{
                    value = LrView.bind("keywords"), -- Bind to the new response property
                    width = 400,
                    height = 100
                },
                f:spacer{
                    height = 10
                },
                f:static_text{
                    title = LrView.bind("geoLocation"), -- Bind to the obtained geolocation
                    width = 400,
                    alignment = 'left',
                    text_color = LrColor(0.4, 0.4, 0.4) -- Grey color
                },
                f:spacer{
                    height = 10
                },                
                f:separator{
                    width = 400
                },
                f:spacer{
                    height = 10
                },
                f:static_text{
                    title = "Prompt:",
                    alignment = 'left'
                },
                f:spacer{f:label_spacing{}},
                f:edit_field{
                    value = LrView.bind("prompt"),
                    width = 400,
                    height = 60
                },
                f:spacer{
                    height = 10
                },
                f:checkbox{
                    title = "Use current keywords",
                    value = LrView.bind("currentKeywords")
                },
                f:spacer{
                    height = 10
                },
                f:checkbox{
                    title = "Use system prompt",
                    value = LrView.bind("useSystemPrompt")
                },
                f:spacer{
                    height = 10
                },
                f:separator{
                    width = 400
                },
                f:spacer{
                    height = 10
                },
                f:row{f:static_text{
                    title = "Model: " .. model,
                    fill_horizontal = 1
                }, f:static_text{
                    alignment = 'right',
                    title = LrView.bind("status"),
                    width = 200,
                    font = "<system/bold>",
                    text_color = LrView.bind("statusColor")
                }},
                f:spacer{
                    height = 10
                },
                f:row{f:push_button{
                    accelerator = "return",  -- Add Enter/Return as a keyboard shortcut
                    title = "Generate &tags ✨",
                    action = function()
                        props.status = "AI is processing..."
                        props.statusColor = LrColor(0.439, 0.345, 0.745)
                        props.currentKeywords = keywordParser(props.keywords)
                        logger:info("Current keywords: " .. tostring(props.currentKeywords))

                        LrTasks.startAsyncTask(function()
                            local apiResponse = sendDataToApi(selectedPhoto, props.prompt, {
                                keywords = props.keywords,
                            }, props.currentKeywords,
                        props.useSystemPrompt, props.geoLocation, props.folderName, props.date)
                            props.response = apiResponse
                            -- Convert the keywords array to a comma-separated string
                            if apiResponse and apiResponse.keywords then
                                if type(apiResponse.keywords) == "table" then -- This is the default case
                                    if props.currentKeywords and props.keywords and props.keywords ~= "" then
                                        logger:info("Simple concat") -- Default
                                        -- Don't add any keywords that already exist in props.keywords
                                        local newKeywords = {}
                                        for _, keyword in ipairs(apiResponse.keywords) do
                                            if not string.find(props.keywords, keyword) then
                                                table.insert(newKeywords, keyword)
                                            end
                                        end
                                        props.keywords = props.keywords .. ", " .. table.concat(newKeywords, ", ")
                                    else
                                        logger:info("Table concat")
                                        props.keywords = table.concat(apiResponse.keywords, ", ")
                                    end
                                else
                                    logger:warn("Keywords is not a table: " .. tostring(apiResponse.keywords))
                                    if props.currentKeywords and props.keywords and props.keywords ~= "" then
                                        props.keywords = props.keywords .. ", " .. tostring(apiResponse.keywords)
                                    else
                                        props.keywords = tostring(apiResponse.keywords)
                                    end
                                end
                            else
                                logger:warn("No keywords in response")
                                if not props.currentKeywords then
                                    props.keywords = ""
                                end
                                -- If currentKeywords is true, keep the existing keywords
                            end
                            props.keywords = string.lower(props.keywords)
                            props.status = "Ready"
                            props.statusColor = LrColor(0.149, 0.616, 0.412)
                            logger:info("Response: " .. JSON:encode(apiResponse))
                        end)
                    end
                }},
                f:spacer{
                    height = 20
                },
                width = 400
            }}
        }

        -- Show the dialog
        local result = LrDialogs.presentModalDialog({
            title = "Lightroom Ollama Tagger",
            contents = c,
            actionVerb = "Save"
        })


        if result == "ok" then
        -- Save the metadata to the photo
        catalog:withWriteAccessDo("Save Ollama Tagger metadata", function()
            -- Check if keywords is a table or string
            local keywordList = props.keywords
            if type(keywordList) == "string" then
                -- Split the string by commas or other separators if needed
                keywordList = {}
                for keyword in string.gmatch(props.keywords, "[^,]+") do
                    table.insert(keywordList, LrStringUtils.trimWhitespace(keyword))
                end
            end
            
            -- Loop through each keyword and add them individually
            for _, keyword in ipairs(keywordList) do
                logger:info("Adding keyword: " .. keyword)
                local keywordObj = catalog:createKeyword(keyword, {}, true, nil, true)
                selectedPhoto:addKeyword(keywordObj)
            end
        end)
        logger:info("Metadata Saved")
        -- LrDialogs.message("Metadata Saved", "Keywords have been saved to the photo.", "info")
        end
    end)
end

LrTasks.startAsyncTask(main)
