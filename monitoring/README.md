# Monitoring

The API and the worker serve health and Prometheus metrics on the operations port (`OPS_PORT`, 9464): `/live`, `/ready`, `/metrics`. It is never published; in Kubernetes the network policy lets only the `monitoring` namespace reach it. Labels never hold customer data.

| File | What it is |
| --- | --- |
| `alerts.yaml` | What to be woken for, what it means for the lab, and what to do first |
| `dashboard.json` | A Grafana dashboard: import it and choose the Prometheus data source |
| `dashboard-check.py` | Checks its queries, and that the app has every metric they use |
| `alerts-test.yaml` | Tests for the rules: `promtool test rules alerts-test.yaml` |

## Scraping

Each target needs the labels `job="lims"`, `app` (the pod's `app` label) and `namespace`:

```yaml
- job_name: lims
  kubernetes_sd_configs: [{ role: endpoints }]
  relabel_configs:
    - { source_labels: [__meta_kubernetes_service_label_lims_example_ops], regex: 'true', action: keep }
    - { source_labels: [__meta_kubernetes_namespace], target_label: namespace }
    - { source_labels: [__meta_kubernetes_pod_label_app], target_label: app }
```

`LimsRestarting` also needs kube-state-metrics.

## Who is told

Alertmanager sends email through any SMTP server. `send_resolved` says when it recovered, and the two times give how long it lasted:

```yaml
route: { receiver: oncall, group_by: [alertname, namespace], routes: [{ matchers: ['severity="critical"'], receiver: oncall, repeat_interval: 1h }] }
receivers:
  - name: oncall
    email_configs: [{ to: oncall@example.com, from: alerts@example.com, smarthost: smtp.example.com:587, auth_username: alerts, auth_password_file: /etc/alertmanager/smtp-password, send_resolved: true }]
```

An alert cannot say that the monitoring itself is down. Point an external uptime monitor at `https://<api domain>/health/ready` as well.
