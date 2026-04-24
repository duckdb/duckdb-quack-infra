# duckdb-quack-infra

Source of truth for the CloudFormation template (`quack.yaml`) and the steps to bake / publish the AMI + template that back the one-click "Launch Stack" demo at <https://test-wasm-carlo.s3.us-east-1.amazonaws.com/index.html>.

## What this deploys

`quack.yaml` is a CloudFormation template that provisions:

- An `AWS::EC2::Instance` from a pre-baked AMI (per-region map in the `Mappings` block) running DuckDB + the quack RPC extension behind nginx + Let's Encrypt TLS.
- An `AWS::EC2::SecurityGroup` opening 80 (ACME) + 443 (HTTPS).
- An `AWS::CloudFormation::WaitCondition` the instance signals once the RPC server is ready.
- CFN `Outputs` carrying the ready URI, per-instance token, and two shareable `shell.duckdb.org` URLs (`QueryURL`, `ConnectURL`).

## Reproduce end-to-end

### 1. Build the AMI

Start from an Ubuntu 24.04 LTS AMI and install the extension + boot.sh.

```bash
# one-off: launch an instance to bake from
aws ec2 run-instances --image-id ami-xxxxxxxxxxxxxxxxx \
    --instance-type t3.micro --region us-east-1 \
    --key-name <your-key>

# push boot.sh to the instance, install it as a systemd unit
scp -i <key> boot.sh ubuntu@<ip>:/tmp/boot.sh
ssh -i <key> ubuntu@<ip>
sudo install -m 0755 /tmp/boot.sh /root/boot.sh
sudo tee /etc/systemd/system/quack-boot.service <<'UNIT'
[Unit]
Description=Quack boot
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/root/boot.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable quack-boot.service
sudo systemctl start quack-boot.service

# upgrade certbot (apt's is too old for LE's ACME v2 profile)
sudo apt-get remove -y certbot
sudo snap install certbot --classic
sudo ln -sf /snap/bin/certbot /usr/bin/certbot
```

Confirm everything works: `sudo ss -tln | grep -E ':1294|:443'` and `curl -sSI https://<ip>.nip.io/rpc`.

### 2. Pre-bake cleanup

```bash
sudo rm -f /home/ubuntu/rpc-token /etc/ssh/ssh_host_*
sudo truncate -s 0 /etc/machine-id
rm -f ~/.bash_history && history -c
exit
```

### 3. Create the AMI

```bash
aws ec2 create-image --instance-id <id> \
    --name "quack-rpc-$(date +%Y-%m-%dT%H%M)" \
    --no-reboot --region us-east-1 \
    --query 'ImageId' --output text
```

Wait for `aws ec2 wait image-available --image-ids <ami> --region us-east-1`.

### 4. Copy to other regions

```bash
for R in us-east-2 us-west-1 us-west-2 eu-west-1 eu-central-1 ap-northeast-1 ap-southeast-1; do
  aws ec2 copy-image --source-region us-east-1 --source-image-id <source-ami> \
      --region $R --name "quack-rpc-$(date +%Y-%m-%dT%H%M)" \
      --query 'ImageId' --output text
done
```

Update the `RegionAmi` mapping in `quack.yaml` with each region's AMI id.

### 5. Make AMI + snapshots public

```bash
for R in us-east-1 us-east-2 us-west-1 us-west-2 eu-west-1 eu-central-1 ap-northeast-1 ap-southeast-1; do
  AMI=<ami-in-$R>
  aws ec2 modify-image-attribute --image-id $AMI \
      --launch-permission '{"Add":[{"Group":"all"}]}' --region $R
  SNAP=$(aws ec2 describe-images --image-ids $AMI --region $R \
      --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' --output text)
  aws ec2 modify-snapshot-attribute --snapshot-id $SNAP \
      --create-volume-permission '{"Add":[{"Group":"all"}]}' --region $R
done
```

### 6. Publish template + landing page

```bash
aws s3 cp quack.yaml s3://duckdb-quack-infra/quack.yaml --acl public-read --region us-east-1
aws cloudformation validate-template --region us-east-1 \
    --template-url https://duckdb-quack-infra.s3.us-east-1.amazonaws.com/quack.yaml
```

### 7. Test-launch a stack

Click the Launch Stack URL at:
https://console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/quickcreate?templateURL=https://duckdb-quack-infra.s3.us-east-1.amazonaws.com/quack.yaml&stackName=quack-demo

```bash
aws cloudformation create-stack --stack-name quack-demo \
    --template-url https://test-wasm-carlo.s3.us-east-1.amazonaws.com/deploy-quack.yaml \
    --region us-east-1
```

Note: not all region are supported, only the one mapped in quack.yaml.
Note: default is `t3.micro`, but other machine could be selected.

Wait ~2 min for `CREATE_COMPLETE`, inspect the Outputs tab, click `ConnectURL` → shell.duckdb.org.

## Try it — SQL snippets

After the stack is up, open the **Outputs** tab and copy `QuackURI` + `Token`. Replace `<uri>` / `<token>` below.

### From local DuckDB

```sql
INSTALL quack FROM core_nightly;
LOAD quack;

-- Register the credentials once per session.
CREATE SECRET quack_credentials (
    TYPE quack,
    SCOPE '<uri>',             -- e.g. 'quack:54.1.2.3.nip.io:443'
    TOKEN '<token>'
);

-- Who did I just launch?
FROM rpc_call('<uri>', 'FROM whoami()');

-- Anything else you'd normally run — shipped verbatim to the remote.
FROM rpc_call('<uri>', 'SELECT 1 + 1');
```

### Sticky session via ATTACH

`ATTACH` keeps server-side state (temp tables, `SET` variables) across calls, which `rpc_call` alone does not.

```sql
ATTACH '<uri>' AS remote (TYPE QUACK);

-- temp table lives on the remote
FROM rpc_call_by_name('remote', 'CREATE TEMP TABLE t AS SELECT range AS x FROM range(10)');
FROM rpc_call_by_name('remote', 'SELECT sum(x) FROM t');

-- Session settings stick.
FROM rpc_call_by_name('remote', 'SET threads = 8');
FROM rpc_call_by_name('remote', 'SELECT current_setting(''threads'')');
```

### Clean up

```bash
aws cloudformation delete-stack --stack-name quack-demo --region us-east-1
```

## Layout

- `quack.yaml` — the CFN template. Canonical source.
- `boot.sh` — installed into every AMI at `/root/boot.sh` + wired via `quack-boot.service`.
- `README.md` — this file.

## Related repos

- [`duckdb-quack`](https://github.com/duckdb/duckdb-quack) — the quack extension source (C++).
