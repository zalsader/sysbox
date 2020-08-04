#!/usr/bin/env bats

#
# Integration test for the sysbox-mgr docker volume manager
#

load ../helpers/run
load ../helpers/sysbox-health

function teardown() {
  sysbox_log_check
}

@test "dockerVolMgr basic" {

  SYSCONT_NAME=$(docker_run --rm nestybox/alpine-docker-dbg:latest tail -f /dev/null)

  #
  # verify things look good inside the sys container
  #

  # "/var/lib/docker" should be mounted to "/var/lib/sysbox/docker/<syscont-name>"; note
  # that in the privileged test container the "/var/lib/sysbox" is itself a mount-point,
  # so it won't show up in findmnt; thus we just grep for "docker/<syscont-name>"
  docker exec "$SYSCONT_NAME" sh -c "findmnt | grep \"/var/lib/docker\" | grep \"docker/$SYSCONT_NAME\""
  [ "$status" -eq 0 ]

  # ownership of "/var/lib/docker" should be root:root
  docker exec "$SYSCONT_NAME" sh -c "stat /var/lib/docker | grep Uid"
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == "Access: (0700/drwx------)  Uid: (    0/    root)   Gid: (    0/    root)" ]]

  #
  # verify things look good on the host
  #

  # there should be a dir with the container's name under /var/lib/sysbox/docker
  run ls /var/lib/sysbox/docker/
  [ "$status" -eq 0 ]
  [[ ${lines[0]} =~ "$SYSCONT_NAME" ]]

  # and that dir should have ownership matching the sysbox user
  run sh -c "cat /etc/subuid | grep sysbox | cut -d\":\" -f2"
  [ "$status" -eq 0 ]
  SYSBOX_UID="$output"

  run sh -c "stat /var/lib/sysbox/docker/\"$SYSCONT_NAME\"* | grep Uid | grep \"$SYSBOX_UID\""
  [ "$status" -eq 0 ]

  docker_stop "$SYSCONT_NAME"
}

@test "dockerVolMgr persistence" {

  # Verify the sys container docker vol persists across container
  # start-stop-start events

  SYSCONT_NAME=$(docker_run nestybox/alpine-docker-dbg:latest tail -f /dev/null)

  docker exec "$SYSCONT_NAME" sh -c "echo data > /var/lib/docker/test"
  [ "$status" -eq 0 ]

  docker_stop "$SYSCONT_NAME"
  [ "$status" -eq 0 ]

  docker start "$SYSCONT_NAME"
  [ "$status" -eq 0 ]

  docker exec "$SYSCONT_NAME" sh -c "cat /var/lib/docker/test"
  [ "$status" -eq 0 ]
  [[ "$output" == "data" ]]

  docker_stop "$SYSCONT_NAME"
  [ "$status" -eq 0 ]

  docker rm "$SYSCONT_NAME"
  [ "$status" -eq 0 ]
}

@test "dockerVolMgr non-persistence" {

  # Verify the sys container docker vol is removed when a
  # container is removed

  SYSCONT_NAME=$(docker_run nestybox/alpine-docker-dbg:latest tail -f /dev/null)

  # short ID -> full ID
  run sh -c "docker inspect \"$SYSCONT_NAME\" | jq '.[0] | .Id' | sed 's/\"//g'"
  [ "$status" -eq 0 ]
  sc_id="$output"

  docker exec "$SYSCONT_NAME" sh -c "echo data > /var/lib/docker/test"
  [ "$status" -eq 0 ]

  run cat "/var/lib/sysbox/docker/$sc_id/test"
  [ "$status" -eq 0 ]
  [[ "$output" == "data" ]]

  docker_stop "$SYSCONT_NAME"
  [ "$status" -eq 0 ]

  run cat "/var/lib/sysbox/docker/$sc_id/test"
  [ "$status" -eq 0 ]

  docker rm "$SYSCONT_NAME"

  run cat "/var/lib/sysbox/docker/$sc_id/test"
  [ "$status" -eq 1 ]

  run cat "/var/lib/sysbox/docker/$sc_id"
  [ "$status" -eq 1 ]
}

@test "dockerVolMgr consecutive restart" {

  SYSCONT_NAME=$(docker_run nestybox/alpine-docker-dbg:latest tail -f /dev/null)

  docker exec "$SYSCONT_NAME" sh -c "echo data > /var/lib/docker/test"
  [ "$status" -eq 0 ]

  docker_stop "$SYSCONT_NAME"
  [ "$status" -eq 0 ]

  for i in $(seq 1 4); do
    docker start "$SYSCONT_NAME"
    [ "$status" -eq 0 ]

    docker exec "$SYSCONT_NAME" sh -c "cat /var/lib/docker/test"
    [ "$status" -eq 0 ]
    [[ "$output" == "data" ]]

    docker_stop "$SYSCONT_NAME"
    [ "$status" -eq 0 ]
  done

  docker rm "$SYSCONT_NAME"
}

@test "dockerVolMgr sync-out" {

  SYSCONT_NAME=$(docker_run nestybox/alpine-docker-dbg:latest tail -f /dev/null)
  rootfs=$(command docker inspect -f '{{.GraphDriver.Data.UpperDir}}' "$SYSCONT_NAME")

  docker exec "$SYSCONT_NAME" sh -c "touch /var/lib/docker/dummyFile"
  [ "$status" -eq 0 ]

  docker_stop "$SYSCONT_NAME"
  [ "$status" -eq 0 ]

  # verify that dummy file was sync'd to the sys container's rootfs
  run ls "$rootfs/var/lib/docker"
  [ "$status" -eq 0 ]
  [[ "$output" == "dummyFile" ]]

  docker start "$SYSCONT_NAME"
  [ "$status" -eq 0 ]

  docker exec "$SYSCONT_NAME" sh -c "rm /var/lib/docker/dummyFile"
  [ "$status" -eq 0 ]

  docker_stop "$SYSCONT_NAME"
  [ "$status" -eq 0 ]

  # verify that dummy file removal was sync'd to the sys container's rootfs
  run ls "$rootfs/var/lib/docker"
  [ "$status" -eq 0 ]
  [[ "$output" == "" ]]

  docker_stop "$SYSCONT_NAME"
  docker rm "$SYSCONT_NAME"
}

#@test "dockerVolMgr sync-in" {
  #
  # TODO: verify dockerVolMgr sync-in by creating a sys container image with contents in /var/lib/docker
  # and checking that the contents are copied to the /var/lib/sysbox/docker/<syscont-name> and
  # that they have the correct ownership. There is a volMgr unit test that verifies this already,
  # but an integration test would be good too.
  #
#}
