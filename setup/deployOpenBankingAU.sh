#/bin/bash

#
# Copyright 2018 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Create Products required for the different APIs
echo Creating API Product: "Products"
apigeetool createProduct -o $APIGEE_ORG -u $APIGEE_USER -p $APIGEE_PASSWORD \
   --productName "CDSProducts" --displayName "Products" --approvalType "auto" --productDesc "Get access to all of API Bank products" \
   --environments $APIGEE_ENV --proxies CDS-Products 

echo Creating API Product: "Accounts"
apigeetool createProduct -o $APIGEE_ORG -u $APIGEE_USER -p $APIGEE_PASSWORD \
   --productName "CDSAccounts" --displayName "Accounts" --approvalType "auto" --productDesc "Get access to Accounts APIs" \
   --environments $APIGEE_ENV --proxies CDS-Accounts --scopes "bank:accounts.basic:read,bank:accounts.detail:read" 

echo Creating API Product: "OIDC"
apigeetool createProduct -o $APIGEE_ORG -u $APIGEE_USER -p $APIGEE_PASSWORD \
   --productName "CDSOIDC" --displayName "OIDC" --approvalType "auto" --productDesc "Get access to authentication and authorisation requests" \
   --environments $APIGEE_ENV --proxies oidc --scopes "openid, profile"

# Create a test developer who will own the test app

echo Creating Test Developer: $CDS_TEST_DEVELOPER_EMAIL
apigeetool createDeveloper -o $APIGEE_ORG -username $APIGEE_USER -p $APIGEE_PASSWORD --email $CDS_TEST_DEVELOPER_EMAIL --firstName "CDS Test" --lastName "Developer"  --userName $CDS_TEST_DEVELOPER_EMAIL

# Create a test app - Store the client key and secret
echo Creating Test App: CDSTestApp...
APP_CREDENTIALS=$(apigeetool createApp -o $APIGEE_ORG -u $APIGEE_USER -p $APIGEE_PASSWORD --name CDSTestApp --apiProducts "CDSAccounts,CDSProducts,CDSOIDC" --email $CDS_TEST_DEVELOPER_EMAIL --json | jq .credentials[0])
APP_KEY=$(echo $APP_CREDENTIALS | jq -r .consumerKey)
APP_SECRET=$(echo $APP_CREDENTIALS | jq -r .consumerSecret)

# Update app attributes
curl https://api.enterprise.apigee.com/v1/organizations/$APIGEE_ORG/developers/$CDS_TEST_DEVELOPER_EMAIL/apps/CDSTestApp \
  -u $APIGEE_ORG:$APIGEE_PASSWORD \
  -H 'Accept: */*' \
  -H 'Authorization: Basic ZGVib3JhZWxraW5AZ29vZ2xlLmNvbTpDcmVzdCQyMiE=' \
  -H 'Content-Type: application/json' \
  -d '{
  "attributes": [
    {
      "name": "Notes",
      "value": "This TestApp is also registered in the OIDC Provider implementation, with the same client_id and client_secret"
    },
    {
      "name": "DisplayName",
      "value": "CDSTestApp"
    }
  ],
  "callbackUrl": "https://httpbin.org/post"
}'

# Generate RSA Private/public key pair for client app:
echo "Generating RSA Private/public key pair for Test App..."
mkdir setup/certs
cd setup/certs
openssl genpkey -algorithm RSA -out ./CDSTestApp_rsa_private.pem -pkeyopt rsa_keygen_bits:2048
openssl rsa -in ./CDSTestApp_rsa_private.pem -pubout -out ./CDSTestApp_rsa_public.pem
echo "Private/public key pair generated and stored in ./setup/certs. Please keep private key safe"

# Generate jwk format for public key (and store it in a file too) - Add missing attributes in jwk generated by command line
APP_JWK=$(pem-jwk ./CDSTestApp_rsa_public.pem  | jq '. + { "kid": "CDSTestApp" } + { "use": "sig" }') 
echo $APP_JWK > ./CDSTestApp.jwk

# Create a new entry in the OIDC provider client configuration for this TestApp,
# so that it is recognised by the OIDC provider as a client
echo "Creating new entry in OIDC Provider configuratation for CDSTestApp"
APP_CLIENT_ENTRY=$(echo '{ "client_id": "'$APP_KEY'", "client_secret": "'$APP_SECRET'", "redirect_uris": ["https://httpbin.org/post"], "response_modes": ["form_post"], "response_types": ["code id_token"], "grant_types": ["authorization_code", "client_credentials","refresh_token","implicit"],"jwks": {"keys": ['$APP_JWK']}}')
OIDC_CLIENT_CONFIG=$(<../../src/apiproxies/oidc/apiproxy/resources/hosted/support/clients.json)
# Write the JQ Filter that we're going to use to a file
echo '. + ['$APP_CLIENT_ENTRY']' > ./tmpJQFilter
echo $OIDC_CLIENT_CONFIG | jq -f ./tmpJQFilter > ../../src/apiproxies/oidc/apiproxy/resources/hosted/support/clients.json
rm ./tmpJQFilter

# Revert to original directory
 cd ../..

# Deploy Shared flows
cd src/shared-flows
for sf in $(ls .) 
do 
    echo Deploying $sf Shared Flow 
    cd $sf
    apigeetool deploySharedflow -o $APIGEE_ORG -e $APIGEE_ENV -u $APIGEE_USER -p $APIGEE_PASSWORD -n $sf 
    cd ..
 done

 # Deploy apiproxies
cd ../apiproxies/banking
for ap in $(ls .) 
do 
    echo Deploying $ap Apiproxy
    cd $ap
    apigeetool deployproxy -o $APIGEE_ORG -e $APIGEE_ENV -u $APIGEE_USER -p $APIGEE_PASSWORD -n $ap
    cd ..
 done

# Deploy oidc proxy
cd ../oidc
echo Deploying oidc Apiproxy
apigeetool deployproxy -o $APIGEE_ORG -e $APIGEE_ENV -u $APIGEE_USER -p $APIGEE_PASSWORD -n oidc


# Revert to original directory
 cd ../../..