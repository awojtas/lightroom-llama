return {
    VERSION = {
        major = 1,
        minor = 0,
        revision = 0
    },
    LrPluginName = "Lightroom Ollama Tagger",
    LrPluginDescription = "Plugin using Ollama model for tagging photos in Lightroom. Initialise by running in Ollama: ollama run minicpm-v",
    LrToolkitIdentifier = "com.awojtas.lightroom.ollama",
    LrPluginInfoUrl = "https://github.com/awojtas/lightroom-ollama",
    LrPluginInfoUrlProvider = "",
    LrSdkVersion = 10.0,
    LrSdkMinimumVersion = 5.0,
    LrLibraryMenuItems = {{
        title = "Lightroom Ollama Tagger...",
        file = "LrLlama.lua"
    }}
}
