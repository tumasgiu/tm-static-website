resource "aws_s3_bucket" "site" {
	bucket = "static.${var.domain}"
	acl    = "public-read"

	website {
		index_document = "index.html"
	}
}

provider "aws" {
	alias  = "virginia"
	region = "us-east-1"
}

locals {
	source_dir = "${path.cwd}/website"
}

resource "archive_file" "sources" {
	type        = "zip"
	source_dir  = "${local.source_dir}"
	output_path = "${path.module}/sources.zip"
}

resource "null_resource" "sync_files_to_s3" {
	triggers {
		hash = "${archive_file.sources.output_md5}"
	}

	provisioner "local-exec" {
		command = "aws s3 sync --acl public-read ${path.cwd}/website s3://${aws_s3_bucket.site.id}"
	}
}

data "aws_route53_zone" "domain" {
	name = "${var.domain}"
}

resource "aws_route53_record" "root" {
	name    = "${var.domain}"
	type    = "A"
	zone_id = "${data.aws_route53_zone.domain.zone_id}"

	alias {
		evaluate_target_health = false // Involves costs if set to true
		name                   = "${aws_cloudfront_distribution.main_site.domain_name}"
		zone_id                = "${aws_cloudfront_distribution.main_site.hosted_zone_id}"
	}
}

resource "aws_route53_record" "www" {
	name    = "www"
	type    = "A"
	zone_id = "${data.aws_route53_zone.domain.zone_id}"

	alias {
		evaluate_target_health = false // Involves costs if set to true
		name                   = "${aws_cloudfront_distribution.main_site.domain_name}"
		zone_id                = "${aws_cloudfront_distribution.main_site.hosted_zone_id}"
	}
}

resource "acme_certificate" "main" {
	account_key_pem    = "${var.acme_account_key_pey}"
	common_name        = "${var.domain}"
	min_days_remaining = 30

	subject_alternative_names = ["www.${var.domain}"]

	dns_challenge {
		provider = "route53"
	}
}

resource "aws_iam_server_certificate" "main" {
	provider = "aws.virginia"

	certificate_body  = "${acme_certificate.main.certificate_pem}"
	certificate_chain = "${acme_certificate.main.issuer_pem}"
	private_key       = "${acme_certificate.main.private_key_pem}"
	path              = "/cloudfront/${md5(var.domain)}/"

	lifecycle {
		create_before_destroy = true
	}
}

resource "aws_cloudfront_distribution" "main_site" {
	aliases = ["${var.domain}", "www.${var.domain}"]

	"origin" {
		domain_name = "${aws_s3_bucket.site.bucket_domain_name}"
		origin_id   = "S3-${var.domain}"
	}

	default_root_object = "index.html"

	"default_cache_behavior" {
		allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
		cached_methods   = ["GET", "HEAD"]
		target_origin_id = "S3-${var.domain}"

		default_ttl = 1800
		"forwarded_values" {
			"cookies" {
				forward = "none"
			}
			query_string = false
		}
		max_ttl     = 3600
		min_ttl     = 900

		viewer_protocol_policy = "redirect-to-https"
	}

	price_class = "PriceClass_100"

	enabled = true

	"restrictions" {
		"geo_restriction" {
			restriction_type = "none"
		}
	}

	"viewer_certificate" {
		iam_certificate_id       = "${aws_iam_server_certificate.main.id}"
		ssl_support_method       = "sni-only"
		minimum_protocol_version = "TLSv1"
	}
}



