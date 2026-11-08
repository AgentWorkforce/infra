"""Offline structural parity/migration guard; not a live state migration proof."""
from pathlib import Path
import json
import re

root = Path(__file__).resolve().parents[1]
text = (root / 'main.tf').read_text()
protected = text.split('resource "aws_opensearch_domain" "this" {', 1)[1].split('resource "aws_opensearch_domain" "disposable" {', 1)[0]
disposable = text.split('resource "aws_opensearch_domain" "disposable" {', 1)[1].split('# A separate resource', 1)[0]
def canonical(block):
    return '\n'.join(line.strip() for line in block.splitlines() if line.strip() and not line.lstrip().startswith('#') and not re.match(r'\s*(count|prevent_destroy)\s*=', line))
assert canonical(protected) == canonical(disposable), 'Every domain argument/security block must remain identical across modes'
assert re.search(r'count\s*=\s*var.disposable\s*\?\s*0\s*:\s*1', protected)
assert re.search(r'prevent_destroy\s*=\s*true', protected)
assert re.search(r'count\s*=\s*var.disposable\s*\?\s*1\s*:\s*0', disposable)
assert re.search(r'prevent_destroy\s*=\s*false', disposable)
assert re.search(r'moved\s*\{\s*from\s*=\s*aws_opensearch_domain.this\s+to\s*=\s*aws_opensearch_domain.this\[0\]\s*\}', text)
variable = (root / 'variables.tf').read_text().split('variable "disposable" {', 1)[1].split('\n}', 1)[0]
assert re.search(r'default\s*=\s*false', variable)
mode = text.split('resource "terraform_data" "creation_mode" {', 1)[1].split('# Preserve the existing protected', 1)[0]
assert re.search(r'input\s*=\s*var.disposable', mode)
assert re.search(r'ignore_changes\s*=\s*\[input\]', mode)
assert 'self.input == var.disposable' in mode and 'postcondition {' in mode
assert 'prevent_destroy' not in mode, 'Mode marker must not prevent legitimate disposable teardown'

print(json.dumps({'ok': True, 'full_domain_configuration_parity': True, 'default_protected': True, 'historical_address_moved_to': 'aws_opensearch_domain.this[0]', 'protected_count_zero_retains_literal_guard': True, 'scope': 'source structure; existing-state execution/production migration requires separate review'}))
