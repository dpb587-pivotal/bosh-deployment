#!/usr/bin/env bash

set -eu

start-bosh

source /tmp/local-bosh/director/env

#
# stemcell metadata/upload
#

tar -xzf stemcell/*.tgz $( tar -tzf stemcell/*.tgz | grep 'stemcell.MF' )
STEMCELL_OS=$( grep -E '^operating_system: ' stemcell.MF | awk '{print $2}' | tr -d "\"'" )
STEMCELL_VERSION=$( grep -E '^version: ' stemcell.MF | awk '{print $2}' | tr -d "\"'" )

bosh -n upload-stemcell stemcell/*.tgz

#
# release metadata/upload
#

cd release
tar -xzf *.tgz $( tar -tzf *.tgz | grep 'release.MF' )
RELEASE_NAME=$( grep -E '^name: ' release.MF | awk '{print $2}' | tr -d "\"'" )
RELEASE_VERSION=$( grep -E '^version: ' release.MF | awk '{print $2}' | tr -d "\"'" )

bosh -n upload-release *.tgz
cd ../

#
# compilation deployment
#

cat > manifest.yml <<EOF
---
name: compilation
releases:
- name: "$RELEASE_NAME"
  version: "$RELEASE_VERSION"
stemcells:
- alias: default
  os: "$STEMCELL_OS"
  version: "$STEMCELL_VERSION"
update:
  canaries: 1
  max_in_flight: 1
  canary_watch_time: 1000 - 90000
  update_watch_time: 1000 - 90000
instance_groups: []
EOF

bosh -n -d compilation deploy manifest.yml
bosh -d compilation export-release $RELEASE_NAME/$RELEASE_VERSION $STEMCELL_OS/$STEMCELL_VERSION

mv *.tgz compiled-release/$( echo *.tgz | sed "s/\.tgz$/-$( date -u +%Y%m%d%H%M%S ).tgz/" )
sha1sum compiled-release/*.tgz

tarball_real=$( echo compiled-release/$RELEASE_NAME-*.tgz )
tarball_nice="$RELEASE_NAME-$RELEASE_VERSION-on-$STEMCELL_OS-stemcell-$STEMCELL_VERSION"

metalink_path="compiled-release-repo/all/$RELEASE_NAME/$STEMCELL_OS/$STEMCELL_VERSION/$RELEASE_NAME-$RELEASE_VERSION.meta4"

mkdir -p "$( dirname "$metalink_path" )"

meta4 create --metalink="$metalink_path"
meta4 set-published --metalink="$metalink_path" "$( date -u +%Y-%m-%dT%H:%M:%SZ )"
meta4 import-file --metalink="$metalink_path" --file="$tarball_nice" --version="$RELEASE_VERSION" "$tarball_real"

if [[ -n "${s3_host:-}" ]]; then
  export AWS_ACCESS_KEY_ID="$s3_access_key_id"
  export AWS_SECRET_ACCESS_KEY="$s3_secret_access_key"

  meta4 file-upload --metalink="$metalink_path" --file="$tarball_nice" "$tarball_real" "s3://$s3_host/$s3_bucket/compiled_releases/$RELEASE_NAME/$( basename "$tarball_real" )"
fi

for product in $products ; do
  metalink_product_path="compiled-release-repo/$product/$RELEASE_NAME-$RELEASE_VERSION.meta4"

  mkdir "$( dirname "$metalink_product_path" )"
  cp "$metalink_path" "$metalink_product_path"
done

git clone --quiet file://$task_dir/compiled-release-repo updated-compiled-release-repo

git config --global user.email "${git_user_email:-ci@localhost}"
git config --global user.name "${git_user_name:-CI Bot}"
export GIT_COMMITTER_NAME="Concourse"
export GIT_COMMITTER_EMAIL="concourse.ci@localhost"

cd compiled-release

git add -A .

git commit -m "$RELEASE_NAME/$RELEASE_VERSION on $STEMCELL_OS/$STEMCELL_VERSION"
