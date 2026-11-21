// npm install --prefix out/schema-tools yaml@2.8.2 ajv@8.17.1
// node scripts/validate-manifests.cjs <extracted alb-controller-crds directory>
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');
const tools = createRequire(path.resolve(process.env.SCHEMA_TOOLS || path.join('out', 'schema-tools', 'package.json')));
const YAML = tools('yaml');
const Ajv = tools('ajv');
const ajv = new Ajv({ strict: false, validateFormats: false, allErrors: true });
const directory = process.argv[2];
if (!directory) throw new Error('Provide the extracted Microsoft CRD installer directory.');

function files(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry =>
    entry.isDirectory() ? files(path.join(dir, entry.name)) : [path.join(dir, entry.name)]);
}
function strictObjects(schema) {
  if (!schema || typeof schema !== 'object') return;
  if (schema.type === 'object' && schema.properties && !schema.additionalProperties) {
    schema.additionalProperties = false;
  }
  for (const [key, value] of Object.entries(schema)) {
    if (key === 'metadata') continue;
    if (Array.isArray(value)) value.forEach(strictObjects);
    else strictObjects(value);
  }
}
const schemas = new Map();
for (const file of files(directory).filter(f => f.endsWith('.yaml'))) {
  for (const doc of YAML.parseAllDocuments(fs.readFileSync(file, 'utf8'))) {
    const crd = doc.toJS();
    if (crd?.kind !== 'CustomResourceDefinition') continue;
    for (const version of crd.spec.versions) {
      const schema = version.schema.openAPIV3Schema;
      strictObjects(schema);
      schemas.set(`${crd.spec.group}/${version.name}:${crd.spec.names.kind}`, ajv.compile(schema));
    }
  }
}
let checked = 0;
for (const file of files('k8s').filter(f => f.endsWith('.yaml'))) {
  for (const doc of YAML.parseAllDocuments(fs.readFileSync(file, 'utf8'))) {
    const value = doc.toJS();
    const validate = schemas.get(`${value.apiVersion}:${value.kind}`);
    if (!validate) {
      if (value.apiVersion.includes('azure.io') || value.apiVersion.includes('gateway.networking')) {
        throw new Error(`Missing authoritative schema: ${value.kind}`);
      }
      continue;
    }
    if (!validate(value)) throw new Error(`${file}: ${JSON.stringify(validate.errors)}`);
    checked++;
  }
}
console.log(`Validated ${checked} custom resources against released Microsoft schemas (CEL not evaluated).`);
