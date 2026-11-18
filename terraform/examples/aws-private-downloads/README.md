# examples/aws-private-downloads

A private S3 bucket of installer downloads, behind CloudFront. Every download
needs a CloudFront signed URL. The bucket is never public, and the only reader
it allows is this CloudFront distribution.

It creates:

- the bucket (private, versioned, SSE-S3, old versions expire) and a bucket
  policy that denies plain HTTP and lets this distribution read
  `<origin_prefix>/*` and nothing else;
- a CloudFront distribution with the bucket as its only origin (origin access
  control, `origin_path = /<origin_prefix>`), HTTPS only, GET and HEAD only,
  nothing cached, and a trusted key group, so a request without a valid
  signature gets 403;
- a CloudFront public key and key group made from the public half of your
  signing key;
- with `domain_name`, an ACM certificate in us-east-1.

The private signing key is never in Terraform, state or this repository. Your
DNS is not managed here: the example creates no DNS records and prints the two
CNAMEs you add at your DNS host.

Objects live at `<origin_prefix>/<channel>/...`. A `<channel>` is an opaque id
you choose. The URL path starts at the channel:
`https://downloads.example.com/example-channel/latest/Example.dmg`.

## Apply

```sh
cp terraform.tfvars.example terraform.tfvars   # fill in your IDs and the public key
terraform init -backend-config=...
terraform plan -out tfplan
terraform apply tfplan
```

The `s3` backend is configured per environment. Read the plan before you apply.

## Import an existing bucket

If the bucket already exists, import it and its settings before the first
apply, so Terraform adopts them instead of creating them. The import ids are
the bucket name.

```sh
terraform import aws_s3_bucket.downloads example-private-downloads
terraform import aws_s3_bucket_ownership_controls.downloads example-private-downloads
terraform import aws_s3_bucket_public_access_block.downloads example-private-downloads
terraform import aws_s3_bucket_versioning.downloads example-private-downloads
terraform import aws_s3_bucket_server_side_encryption_configuration.downloads example-private-downloads
terraform import aws_s3_bucket_lifecycle_configuration.downloads example-private-downloads
terraform import aws_s3_bucket_policy.downloads example-private-downloads   # only if one exists
```

An existing CloudFront setup is imported the same way. The ids are the ones
CloudFront shows (an origin access control id, a key id, a key group id and a
distribution id), and the certificate's ARN:

```sh
terraform import aws_cloudfront_origin_access_control.downloads <oac-id>
terraform import 'aws_cloudfront_public_key.signing["example-signing-1"]' <public-key-id>
terraform import aws_cloudfront_key_group.signing <key-group-id>
terraform import aws_cloudfront_distribution.downloads <distribution-id>
# with domain_name; the certificate is in us-east-1 (the aliased provider handles that)
terraform import 'aws_acm_certificate.downloads[0]' <certificate-arn>
```

Set `origin_access_control_name` and `key_group_name` to the existing names,
or the plan renames them.

Warning: the map key and the PEM in `signing_public_keys` must equal the
existing key's name and encoded key byte for byte, including the trailing
newline. A public key cannot be changed in place, so any difference plans a
replacement, which gives a new key id and stops every link already issued.
Run `terraform plan` and check that no public key is replaced before you apply.

Then plan. Expect the bucket policy, lifecycle rules and tags to show changes
where the existing bucket differs. Stop and read each one. The bucket policy
replaces any existing policy, so make sure nothing else depends on it.

## Attach a domain (two steps)

1. Set `domain_name = "downloads.example.com"` and leave `attach_domain = false`.
   Apply. This creates the certificate and a distribution on its CloudFront
   domain. Read the outputs `certificate_validation_records` and
   `distribution_domain_name`.
2. At your DNS host, add the validation CNAME (name, type and value from
   `certificate_validation_records`). Wait until ACM shows the certificate as
   issued. Then add a CNAME from `downloads.example.com` to
   `distribution_domain_name`, set `attach_domain = true` and apply.

`attach_domain = true` without `domain_name` fails at plan.

## Generate the key pair

Do this on a trusted machine. The private half goes straight into a secret
manager. Never commit either real key, and never put the private half in
tfvars.

```sh
openssl genrsa -out signing-key.pem 2048
openssl rsa -in signing-key.pem -pubout -out signing-key.pub.pem
# store signing-key.pem in your secret manager, then delete the local copy
shred -u signing-key.pem
```

Put the contents of `signing-key.pub.pem` in `signing_public_keys`, under a
name of your choice (`example-signing-1`). The output `signing_public_key_ids`
maps each name to its CloudFront key id, which is the `Key-Pair-Id` of a signed
URL.

## Publish and promote a build

[`scripts/publish.sh`](scripts/publish.sh) needs only the `aws` CLI and
coreutils. Use credentials that may write to the bucket.

```sh
scripts/publish.sh upload example-private-downloads desktop example-channel build-0001 ./dist
```

This uploads every file in `./dist` to
`s3://example-private-downloads/desktop/example-channel/builds/build-0001/` and
writes a `SHA256SUMS.txt` beside them. It refuses to reuse a build id.

To make a build the current one, write a map file. Each line is a stable name,
a tab, and a file name in the build:

```text
Example.dmg	Example-1.2.3-arm64.dmg
Example.exe	Example-1.2.3-setup.exe
```

```sh
scripts/publish.sh promote example-private-downloads desktop example-channel build-0001 map.txt
```

Each file is copied server side onto `<channel>/latest/<stable name>` with a
download file name (`Content-Disposition`), a content type and
`Cache-Control: no-store`. Sizes are checked after the copy. Then
`latest/SHA256SUMS.txt` and `latest/VERSION.txt` are written. Links to the
stable names never change, and nothing is cached, so the next request gets the
new build. Copies above 5 GB are out of scope.

## Sign a link

[`scripts/sign-url.sh`](scripts/sign-url.sh) needs only `openssl` and coreutils.
It reads the private key from a file path (a process substitution works, so the
key need not touch disk) and prints a signed URL for each URL you give it.

```sh
scripts/sign-url.sh 'https://downloads.example.com/example-channel/latest/*' \
  2030-01-31T12:00:00Z "$KEY_PAIR_ID" <(secret-manager-read signing-key) \
  https://downloads.example.com/example-channel/latest/Example.dmg \
  https://downloads.example.com/example-channel/latest/Example.exe
```

The first argument is the resource the signature covers. A wildcard lets one
signature cover several files. The second is the expiry, in UTC (a date or an
epoch). A time in the past is refused. Pick the shortest expiry that works.
[`tests/sign-url-test.sh`](tests/sign-url-test.sh) signs with a throwaway key
and verifies the result with `openssl`.

After the expiry, CloudFront answers 403 and the recipient sees an access
denied page. The same happens for a missing file, a bad signature and a missing
signature. Send a new link.

## Rotate the key

Add a second entry to `signing_public_keys` with a new name and its new public
key, and apply. Both keys are now in the key group, so links signed with
either one work. Sign new links with the new key id. Remove the old entry only
when links signed by the old key should stop working: from that apply, every
link signed with it fails with a 403, even before its expiry. There is no
per-link revoke.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11 |
| aws | >= 6.0, < 7.0 |

### Providers

| Name | Version |
| ---- | ------- |
| aws | >= 6.0, < 7.0 |
| aws.us\_east\_1 | >= 6.0, < 7.0 |

### Resources

| Name | Type |
| ---- | ---- |
| [aws_acm_certificate.downloads](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate) | resource |
| [aws_cloudfront_distribution.downloads](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_distribution) | resource |
| [aws_cloudfront_key_group.signing](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_key_group) | resource |
| [aws_cloudfront_origin_access_control.downloads](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_origin_access_control) | resource |
| [aws_cloudfront_public_key.signing](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_public_key) | resource |
| [aws_s3_bucket.downloads](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.downloads](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_ownership_controls.downloads](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.downloads](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.downloads](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.downloads](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.downloads](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_cloudfront_cache_policy.caching_disabled](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/cloudfront_cache_policy) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | The AWS account that owns the bucket and the distribution. The providers refuse any other. | `string` | n/a | yes |
| bucket\_name | The private downloads bucket. An existing bucket is imported (see the README). | `string` | n/a | yes |
| region | The bucket's region. | `string` | n/a | yes |
| signing\_public\_keys | CloudFront public keys that verify signed URLs: key name => PEM of an RSA 2048 public key. The name is the CloudFront key's name (an existing key is imported under its own name). The private halves never go into Terraform, state or the repository. Add a second entry to rotate with an overlap. | `map(string)` | n/a | yes |
| attach\_domain | false: create the certificate but keep the default CloudFront domain. true: serve domain\_name with that certificate. Set it only after the validation CNAME exists and the certificate is issued. | `bool` | `false` | no |
| domain\_name | A hostname for the downloads (its DNS is not managed here), or null for the CloudFront domain only. Set, it creates a certificate in us-east-1 and outputs its validation record. | `string` | `null` | no |
| key\_group\_name | Name of the key group. null: <bucket\_name>-signers. | `string` | `null` | no |
| noncurrent\_version\_days | Days a replaced or deleted object version is kept (versioning is on, for recovery). | `number` | `180` | no |
| origin\_access\_control\_name | Name of the origin access control. null: <bucket\_name>-oac. | `string` | `null` | no |
| origin\_prefix | The one key prefix CloudFront may read and serves as its root. Objects live at <origin\_prefix>/<channel>/..., and the URL path starts at <channel>. | `string` | `"desktop"` | no |
| price\_class | CloudFront price class. | `string` | `"PriceClass_100"` | no |
| tags | Tags for the bucket, the distribution and the certificate. | `map(string)` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| bucket | The downloads bucket. |
| certificate\_arn | The us-east-1 certificate ARN, or null without domain\_name. |
| certificate\_validation\_records | DNS records to add at the DNS host to validate the certificate (empty without domain\_name). |
| distribution\_arn | The CloudFront distribution ARN (the bucket policy's AWS:SourceArn). |
| distribution\_domain\_name | The CloudFront domain name. Point the CNAME for domain\_name here. |
| distribution\_id | The CloudFront distribution id. |
| key\_group\_id | The key group id (the default behaviour's trusted key group). |
| signing\_public\_key\_ids | Key name => CloudFront public key id. The id is the Key-Pair-Id of a signed URL. |
<!-- END_TF_DOCS -->
