import requests

url = "http://cr-render:8080/render?format=docx"
r = requests.post(url, json=global_final_dict)

# r.content → binaire DOCX



provider = os.environ.get("PIPELINE_PROVIDER", "openai")
api_base = os.environ.get("PIPELINE_API_BASE", "http://openai-adapter:5055")
api_key  = os.environ.get("PIPELINE_API_KEY", "")
model    = os.environ.get("PIPELINE_MODEL", "annoter")
preset   = os.environ.get("PIPELINE_PRESET", "equilibre")



pwsh /pipeline/powershell/cr_reunion_pipeline_fulljson.ps1 `
  -CsvPath "/data/jobs/<job>/input.csv" `
  -OutDir "/data/jobs/<job>/out" `
  -Provider "openai" `
  -ApiBase "http://openai-adapter:5055" `
  -ApiKey "<clé adapter si activée>" `
  -Model "gpt-4o-mini" `
  -Preset "equilibre"
