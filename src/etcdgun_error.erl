-module(etcdgun_error).

-export([from_grpc_error/1]).

-export_type([
    etcd_error/0,
    etcd_error_reason/0
]).

-type etcd_error() :: {etcd_error, Reason :: etcd_error_reason()}.
-type etcd_error_reason() ::
    empty_key
  | key_not_found
  | value_provided
  | lease_provided
  | too_many_ops
  | duplicate_key
  | compacted
  | future_rev
  | no_space
  | lease_not_found
  | lease_exist
  | lease_ttl_too_large
  | watch_canceled
  | member_exist
  | peer_urlexist
  | member_not_enough_started
  | member_bad_urls
  | member_not_found
  | member_not_learner
  | learner_not_ready
  | too_many_learners
  | cluster_id_mismatch
  | request_too_large
  | request_too_many_requests
  | root_user_not_exist
  | root_role_not_exist
  | user_already_exist
  | user_empty
  | user_not_found
  | role_already_exist
  | role_not_found
  | role_empty
  | auth_failed
  | permission_not_given
  | permission_denied
  | role_not_granted
  | permission_not_granted
  | auth_not_enabled
  | invalid_auth_token
  | invalid_auth_mgmt
  | auth_old_revision
  | no_leader
  | not_leader
  | leader_changed
  | not_capable
  | stopped
  | timeout
  | timeout_due_to_leader_fail
  | timeout_due_to_connection_lost
  | timeout_wait_applied_index
  | unhealthy
  | corrupt
  | not_supported_for_learner
  | bad_leader_transferee
  | cluster_version_unavailable
  | wrong_downgrade_version_format
  | invalid_downgrade_target_version
  | downgrade_in_process
  | no_inflight_downgrade
  | canceled
  | deadline_exceeded.

from_grpc_error({grpc_error, ErrorName, ErrorDesc} = E) ->
    case from_grpc_error_desc({ErrorName, ErrorDesc}) of
        unknown -> E;
        {etcd_error, _} = EtcdError -> EtcdError
    end.

from_grpc_error_desc({invalid_argument,    <<"etcdserver: key is not provided">>})                                            -> {etcd_error, empty_key};
from_grpc_error_desc({invalid_argument,    <<"etcdserver: key not found">>})                                                  -> {etcd_error, key_not_found};
from_grpc_error_desc({invalid_argument,    <<"etcdserver: value is provided">>})                                              -> {etcd_error, value_provided};
from_grpc_error_desc({invalid_argument,    <<"etcdserver: lease is provided">>})                                              -> {etcd_error, lease_provided};
from_grpc_error_desc({invalid_argument,    <<"etcdserver: too many operations in txn request">>})                             -> {etcd_error, too_many_ops};
from_grpc_error_desc({invalid_argument,    <<"etcdserver: duplicate key given in txn request">>})                             -> {etcd_error, duplicate_key};
from_grpc_error_desc({out_of_range,        <<"etcdserver: mvcc: required revision has been compacted">>})                     -> {etcd_error, compacted};
from_grpc_error_desc({out_of_range,        <<"etcdserver: mvcc: required revision is a future revision">>})                   -> {etcd_error, future_rev};
from_grpc_error_desc({resource_exhausted,  <<"etcdserver: mvcc: database space exceeded">>})                                  -> {etcd_error, no_space};
from_grpc_error_desc({not_found,           <<"etcdserver: requested lease not found">>})                                      -> {etcd_error, lease_not_found};
from_grpc_error_desc({failed_precondition, <<"etcdserver: lease already exists">>})                                           -> {etcd_error, lease_exist};
from_grpc_error_desc({out_of_range,        <<"etcdserver: too large lease TTL">>})                                            -> {etcd_error, lease_ttl_too_large};
from_grpc_error_desc({canceled,            <<"etcdserver: watch canceled">>})                                                 -> {etcd_error, watch_canceled};
from_grpc_error_desc({failed_precondition, <<"etcdserver: member ID already exist">>})                                        -> {etcd_error, member_exist};
from_grpc_error_desc({failed_precondition, <<"etcdserver: Peer URLs already exists">>})                                       -> {etcd_error, peer_urlexist};
from_grpc_error_desc({failed_precondition, <<"etcdserver: re-configuration failed due to not enough started members">>})      -> {etcd_error, member_not_enough_started};
from_grpc_error_desc({invalid_argument,    <<"etcdserver: given member URLs are invalid">>})                                  -> {etcd_error, member_bad_urls};
from_grpc_error_desc({not_found,           <<"etcdserver: member not found">>})                                               -> {etcd_error, member_not_found};
from_grpc_error_desc({failed_precondition, <<"etcdserver: can only promote a learner member">>})                              -> {etcd_error, member_not_learner};
from_grpc_error_desc({failed_precondition, <<"etcdserver: can only promote a learner member which is in sync with leader">>}) -> {etcd_error, learner_not_ready};
from_grpc_error_desc({failed_precondition, <<"etcdserver: too many learner members in cluster">>})                            -> {etcd_error, too_many_learners};
from_grpc_error_desc({failed_precondition, <<"etcdserver: cluster ID mismatch">>})                                            -> {etcd_error, cluster_id_mismatch};
from_grpc_error_desc({invalid_argument,    <<"etcdserver: request is too large">>})                                           -> {etcd_error, request_too_large};
from_grpc_error_desc({resource_exhausted,  <<"etcdserver: too many requests">>})                                              -> {etcd_error, request_too_many_requests};
from_grpc_error_desc({failed_precondition, <<"etcdserver: root user does not exist">>})                                       -> {etcd_error, root_user_not_exist};
from_grpc_error_desc({failed_precondition, <<"etcdserver: root user does not have root role">>})                              -> {etcd_error, root_role_not_exist};
from_grpc_error_desc({failed_precondition, <<"etcdserver: user name already exists">>})                                       -> {etcd_error, user_already_exist};
from_grpc_error_desc({invalid_argument,    <<"etcdserver: user name is empty">>})                                             -> {etcd_error, user_empty};
from_grpc_error_desc({failed_precondition, <<"etcdserver: user name not found">>})                                            -> {etcd_error, user_not_found};
from_grpc_error_desc({failed_precondition, <<"etcdserver: role name already exists">>})                                       -> {etcd_error, role_already_exist};
from_grpc_error_desc({failed_precondition, <<"etcdserver: role name not found">>})                                            -> {etcd_error, role_not_found};
from_grpc_error_desc({invalid_argument,    <<"etcdserver: role name is empty">>})                                             -> {etcd_error, role_empty};
from_grpc_error_desc({invalid_argument,    <<"etcdserver: authentication failed, invalid user ID or password">>})             -> {etcd_error, auth_failed};
from_grpc_error_desc({invalid_argument,    <<"etcdserver: permission not given">>})                                           -> {etcd_error, permission_not_given};
from_grpc_error_desc({permission_denied,   <<"etcdserver: permission denied">>})                                              -> {etcd_error, permission_denied};
from_grpc_error_desc({failed_precondition, <<"etcdserver: role is not granted to the user">>})                                -> {etcd_error, role_not_granted};
from_grpc_error_desc({failed_precondition, <<"etcdserver: permission is not granted to the role">>})                          -> {etcd_error, permission_not_granted};
from_grpc_error_desc({failed_precondition, <<"etcdserver: authentication is not enabled">>})                                  -> {etcd_error, auth_not_enabled};
from_grpc_error_desc({unauthenticated,     <<"etcdserver: invalid auth token">>})                                             -> {etcd_error, invalid_auth_token};
from_grpc_error_desc({invalid_argument,    <<"etcdserver: invalid auth management">>})                                        -> {etcd_error, invalid_auth_mgmt};
from_grpc_error_desc({invalid_argument,    <<"etcdserver: revision of auth store is old">>})                                  -> {etcd_error, auth_old_revision};
from_grpc_error_desc({unavailable,         <<"etcdserver: no leader">>})                                                      -> {etcd_error, no_leader};
from_grpc_error_desc({failed_precondition, <<"etcdserver: not leader">>})                                                     -> {etcd_error, not_leader};
from_grpc_error_desc({unavailable,         <<"etcdserver: leader changed">>})                                                 -> {etcd_error, leader_changed};
from_grpc_error_desc({unavailable,         <<"etcdserver: not capable">>})                                                    -> {etcd_error, not_capable};
from_grpc_error_desc({unavailable,         <<"etcdserver: server stopped">>})                                                 -> {etcd_error, stopped};
from_grpc_error_desc({unavailable,         <<"etcdserver: request timed out">>})                                              -> {etcd_error, timeout};
from_grpc_error_desc({unavailable,         <<"etcdserver: request timed out, possibly due to previous leader failure">>})     -> {etcd_error, timeout_due_to_leader_fail};
from_grpc_error_desc({unavailable,         <<"etcdserver: request timed out, possibly due to connection lost">>})             -> {etcd_error, timeout_due_to_connection_lost};
from_grpc_error_desc({unavailable,         <<"etcdserver: request timed out, waiting for the applied index took too long">>}) -> {etcd_error, timeout_wait_applied_index};
from_grpc_error_desc({unavailable,         <<"etcdserver: unhealthy cluster">>})                                              -> {etcd_error, unhealthy};
from_grpc_error_desc({data_loss,           <<"etcdserver: corrupt cluster">>})                                                -> {etcd_error, corrupt};
from_grpc_error_desc({unavailable,         <<"etcdserver: rpc not supported for learner">>})                                  -> {etcd_error, not_supported_for_learner};
from_grpc_error_desc({failed_precondition, <<"etcdserver: bad leader transferee">>})                                          -> {etcd_error, bad_leader_transferee};
from_grpc_error_desc({unavailable,         <<"etcdserver: cluster version not found during downgrade">>})                     -> {etcd_error, cluster_version_unavailable};
from_grpc_error_desc({invalid_argument,    <<"etcdserver: wrong downgrade target version format">>})                          -> {etcd_error, wrong_downgrade_version_format};
from_grpc_error_desc({invalid_argument,    <<"etcdserver: invalid downgrade target version">>})                               -> {etcd_error, invalid_downgrade_target_version};
from_grpc_error_desc({failed_precondition, <<"etcdserver: cluster has a downgrade job in progress">>})                        -> {etcd_error, downgrade_in_process};
from_grpc_error_desc({failed_precondition, <<"etcdserver: no inflight downgrade job">>})                                      -> {etcd_error, no_inflight_downgrade};
from_grpc_error_desc({canceled,            <<"etcdserver: request canceled">>})                                               -> {etcd_error, canceled};
from_grpc_error_desc({deadline_exceeded,   <<"etcdserver: context deadline exceeded">>})                                      -> {etcd_error, deadline_exceeded};
from_grpc_error_desc(_) -> unknown.
