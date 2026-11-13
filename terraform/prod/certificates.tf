# One certificate per company for <domain> and api.<domain>. Kept here, not in the lab module, because the HTTPS
# listener needs the first company's certificate before any company's routing rules can be attached to it.

resource "aws_acm_certificate" "lab" {
  for_each                  = var.labs
  domain_name               = each.value.domain
  subject_alternative_names = ["api.${each.value.domain}"]
  validation_method         = "DNS"
  tags                      = { Lab = each.key }
  lifecycle { create_before_destroy = true }
}

locals {
  # Validation records for companies whose DNS is in Route 53, keyed by names known before apply (the record
  # values themselves only exist once the certificate is requested).
  cert_records = merge([
    for k, v in var.labs : {
      for d in [v.domain, "api.${v.domain}"] : "${k}/${d}" => {
        zone_id = v.dns_zone_id
        option  = one([for o in aws_acm_certificate.lab[k].domain_validation_options : o if o.domain_name == d])
      }
    } if v.dns_zone_id != null
  ]...)
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.cert_records
  zone_id  = each.value.zone_id
  name     = each.value.option.resource_record_name
  type     = each.value.option.resource_record_type
  records  = [each.value.option.resource_record_value]
  ttl      = 300
}

# Waits until each certificate is issued. With DNS outside Route 53, add the records from the
# certificate_validation output first (docs/aws/companies.md, step "Prove the domain").
resource "aws_acm_certificate_validation" "lab" {
  for_each                = var.labs
  certificate_arn         = aws_acm_certificate.lab[each.key].arn
  validation_record_fqdns = each.value.dns_zone_id == null ? null : [for k, r in aws_route53_record.cert_validation : r.fqdn if startswith(k, "${each.key}/")]
}
