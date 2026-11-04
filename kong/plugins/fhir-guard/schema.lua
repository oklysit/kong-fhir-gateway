-- Config schema for the fhir-guard plugin.
-- Kong reads this file when it loads the plugin. It says which settings the plugin accepts.

return {
  -- The plugin name. The route in kong.yml.tpl and KONG_PLUGINS in docker-compose.yml use this same name.
  name = "fhir-guard",

  -- The list of fields. Kong checks a plugin's config against these.
  fields = {
    -- The plugin takes no settings. The config is an empty record, so every rule is fixed in handler.lua.
    { config = { type = "record", fields = {} } },
  },
}
