# creating-qa-environment-example

AWS上にPRごとの検証環境を作成するための例

![image](https://user-images.githubusercontent.com/59072363/137606681-aa21eda2-f403-4d71-bb46-829dcf1a76cb.png)

## 利用方法

下記の作業をすることで、PRごとに検証環境が作成されます。

### Secretsの設定

Secretsに下記を追加します。

- AWS_ACCESS_KEY_ID
  - GitHub Actions で使用する IAM ユーザーのアクセスキー ID
- AWS_SECRET_ACCESS_KEY
  - GitHub Actions で使用する IAM ユーザーのシークレットアクセスキー
- PERSONAL_ACCESS_TOKEN
  - CodeBuild で使用する GitHub の Personal access token
- DOMAIN
  - 検証環境のドメイン
- TFSTATE_BUCKET
  - tfstate を格納する S3 バケット

### ワークフローの移動

このリポジトリはワークフローを`.gihub/workflows`に配置していないので、`workflows`を`.github`配下に移動します。

### 共通リソースの作成

VPC, ALB, CodeBuild など検証環境の共通リソースを作成します。

```sh
cd terraform/common
terraform init -backend-config='bucket=<Secrets TFSTATE_BUCKETに設定したS3バケット>'
terraform apply -var domain='<Secrets DOMAINに設定したドメイン>'
```
