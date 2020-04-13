program all_currents
     use hartree_mod, only : evc_uno,evc_due,trajdir 
     USE environment, ONLY: environment_start, environment_end
     use io_global, ONLY: ionode 
     use wavefunctions, only : evc
     use kinds, only : dp
     !trajectory reading stuff
     use ions_base, only : nat
     use cpv_traj , only : cpv_trajectory, &
         cpv_trajectory_initialize, cpv_trajectory_deallocate
     
!from ../PW/src/pwscf.f90
  USE mp_global,            ONLY : mp_startup
  USE mp_world,             ONLY : world_comm
     use mp, ONLY: mp_bcast, mp_barrier
  USE mp_pools,             ONLY : intra_pool_comm
  USE mp_bands,             ONLY : intra_bgrp_comm, inter_bgrp_comm
  !USE mp_exx,               ONLY : negrp
  USE read_input,           ONLY : read_input_file
  USE command_line_options, ONLY : input_file_, command_line, ndiag_, nimage_
  USE check_stop,           ONLY : check_stop_init
!from ../Modules/read_input.f90
     USE read_namelists_module, ONLY : read_namelists
     USE read_cards_module,     ONLY : read_cards

     implicit none
     integer :: exit_status,ios
     type(cpv_trajectory) :: traj

!from ../PW/src/pwscf.f90
     include 'laxlib.fh'

!from ../PW/src/pwscf.f90
     CALL mp_startup()
     CALL laxlib_start ( ndiag_, world_comm, intra_bgrp_comm, &
                         do_distr_diag_inside_bgrp_ = .TRUE. )
     CALL set_mpi_comm_4_solvers( intra_pool_comm, intra_bgrp_comm, &
                               inter_bgrp_comm )
     CALL environment_start('PWSCF')

     IF (ionode) THEN
        CALL input_from_file()
        ! all_currents input
        call read_all_currents_namelists( 5 )
     endif
        ! PW input
        call read_namelists( 'PW', 5 )
        call read_cards( 'PW', 5 )

     call check_input()
 
     call mp_barrier(intra_pool_comm)
     call bcast_all_current_namelist() 
     call iosys()    ! ../PW/src/input.f90    save in internal variables
     call check_stop_init() ! ../PW/src/input.f90
     call setup()    ! ../PW/src/setup.f90    setup the calculation
     call init_run() ! ../PW/src/init_run.f90 allocate stuff

     ! now scf is ready to start, but I first initialize energy current stuff 
     call allocate_zero() ! only once per all trajectory
     call init_zero() ! only once per all trajectory
     call setup_nbnd_occ() ! only once per all trajectory

     if (ionode) then
         !initialize trajectory reading
         call cpv_trajectory_initialize(traj,trajdir,nat,1.0_dp,1.0_dp,1.0_dp,ios=ios,circular=.true.)
         if (ios == 0 ) then
             write(*,*) 'After first step from input file, I will read from the CPV trajectory ',trajdir
         else
             write(*,*) 'Calculating only a single step from input file'
         endif 
     endif
     do
         call run_pwscf(exit_status)
         if (exit_status /= 0 ) goto 100

         call prepare_next_step() ! this stores value of evc and setup tau and ion_vel

         call run_pwscf(exit_status)
         if (exit_status /= 0 ) goto 100
         if (allocated(evc_uno)) then
             evc_uno=evc
         else
             allocate(evc_uno, source=evc)
         end if
         
         !calculate energy current
         call routine_hartree()
         call routine_zero()
         call write_results(traj)
         !read new velocities and positions and continue, or exit the loop     
         if (.not. read_next_step(traj)) exit
     end do

     ! shutdown stuff
100     call laxlib_end()
     call cpv_trajectory_deallocate(traj)
     call deallocate_zero()
     if (allocated(evc_uno)) deallocate (evc_uno)
     if (allocated(evc_due)) deallocate (evc_due)
     call stop_run( exit_status )
     call do_stop( exit_status )
     stop

contains


subroutine write_results(traj)
   use hartree_mod
   use zero_mod
   use io_global, ONLY: ionode 
     use cpv_traj , only : cpv_trajectory, cpv_trajectory_get_last_step
   use traj_object, only : timestep      
   implicit none
   type(cpv_trajectory),intent(in)  :: traj
   type(timestep) :: ts
   integer :: iun,step
   integer, external :: find_free_unit
   
   if (traj%traj%nsteps > 0) then
       call cpv_trajectory_get_last_step(traj,ts)
       step=ts%nstep
   else
       step=0
   endif
   if (ionode) then
      iun = find_free_unit()
      open (iun, file=trim(file_output), position='append')
      write (iun, *) 'Passo: ',step
      write (iun, '(A,10E20.12)') 'h&K-XC', J_xc(:)
      write (iun, '(A,10E20.12)') 'h&K-H', J_hartree(:)
      write (iun, '(A,1F15.7,9E20.12)') 'h&K-K', delta_t, J_kohn(1:3), J_kohn_a(1:3), J_kohn_b(1:3)
      write (iun, '(A,3E20.12)') 'h&K-ELE', J_electron(1:3)
         write (iun, '(A,3E20.12)') 'ionic:', i_current(:)
         write (iun, '(A,3E20.12)') 'ionic_a:', i_current_a(:)
         write (iun, '(A,3E20.12)') 'ionic_b:', i_current_b(:)
         write (iun, '(A,3E20.12)') 'ionic_c:', i_current_c(:)
         write (iun, '(A,3E20.12)') 'ionic_d:', i_current_d(:)
         write (iun, '(A,3E20.12)') 'ionic_e:', i_current_e(:)
         write (iun, '(A,3E20.12)') 'zero:', z_current(:)
         write (iun,'(A,3E20.12)') 'total: ', J_xc+J_hartree+J_kohn+i_current+z_current
         write (*,'(A,3E20.12)') 'total energy current: ', J_xc+J_hartree+J_kohn+i_current+z_current
         close (iun)
      end if

end subroutine

subroutine read_all_currents_namelists(iunit)
     use zero_mod
     use hartree_mod
     use io_global, ONLY: stdout, ionode, ionode_id
     implicit none
     integer, intent(in) :: iunit
     integer :: ios
     CHARACTER(LEN=256), EXTERNAL :: trimcheck
     
     NAMELIST /energy_current/ delta_t, init_linear, &
        file_output, trajdir, vel_input_units ,&
        eta, n_max, l_zero

     !
     !   set default values for variables in namelist
     !
     delta_t = 1.d0
     n_max = 5 ! number of periodic cells in each direction used to sum stuff in zero current
     eta = 1.0 ! ewald sum convergence parameter
     init_linear = "nothing" ! 'scratch' or 'restart'. If 'scratch', saves a restart file in project routine. If 'restart', it starts from the saved restart file, and then save again it.
     file_output = "current_hz"
     READ (iunit, energy_current, IOSTAT=ios)
     IF (ios /= 0) CALL errore('main', 'reading energy_current namelist', ABS(ios))    

end subroutine

subroutine bcast_all_current_namelist()
     use zero_mod
     use hartree_mod
     use io_global, ONLY: stdout, ionode, ionode_id
     use mp_world, ONLY: mpime, world_comm
     use mp, ONLY: mp_bcast !, mp_barrier
     implicit none
     CALL mp_bcast(trajdir, ionode_id, world_comm)
     CALL mp_bcast(delta_t, ionode_id, world_comm)
     CALL mp_bcast(eta, ionode_id, world_comm)
     CALL mp_bcast(n_max, ionode_id, world_comm)
     CALL mp_bcast(init_linear, ionode_id, world_comm)
     CALL mp_bcast(file_output, ionode_id, world_comm)

end subroutine

subroutine check_input()
     use input_parameters, only : rd_pos, tapos, rd_vel, tavel, atomic_positions, ion_velocities
use  ions_base,     ONLY :  tau, tau_format, nat
     use zero_mod, only : vel_input_units, ion_vel
     use hartree_mod, only : delta_t
     implicit none
     if (.not. tavel) &
        call errore('read_vel', 'error: must provide velocities in input',1)
     if (ion_velocities /= 'from_input') &
        call errore('read_vel', 'error: atomic_velocities must be "from_input"',1)

end subroutine


subroutine run_pwscf(exit_status)
USE control_flags,        ONLY : conv_elec, gamma_only, ethr, lscf, treinit_gvecs
 USE check_stop,           ONLY : check_stop_init, check_stop_now
USE qexsd_module,         ONLY : qexsd_set_status
implicit none
INTEGER, INTENT(OUT) :: exit_status
exit_status=0
     IF ( .NOT. lscf) THEN
        CALL non_scf()
     ELSE
        CALL electrons()
     END IF
     IF ( check_stop_now() .OR. .NOT. conv_elec ) THEN
        IF ( check_stop_now() ) exit_status = 255
        IF ( .NOT. conv_elec )  exit_status =  2
        CALL qexsd_set_status(exit_status)
        CALL punch( 'config' )
        RETURN
     ENDIF
end subroutine

subroutine prepare_next_step()
USE extrapolation,        ONLY : update_pot
USE control_flags,        ONLY : ethr
use  ions_base,     ONLY :  tau, tau_format, nat
use cell_base, only : alat
use dynamics_module, only : vel
use io_global, ONLY: ionode, ionode_id
USE mp_world,             ONLY : world_comm
use mp, ONLY: mp_bcast, mp_barrier
use hartree_mod, only : evc_due,delta_t
use zero_mod, only : vel_input_units, ion_vel
use wavefunctions, only : evc 
     implicit none
     !save old evc
     if (allocated(evc_due)) then
         evc_due=evc
     else
         allocate(evc_due, source=evc)
     end if
     !set new positions
     if (ionode) then
         if (vel_input_units=='CP') then ! atomic units of cp are different
            vel= 2.d0 * vel
         else if (vel_input_units=='PW') then
            !do nothing
         else
            call errore('read_vel', 'error: unknown vel_input_units',1 )
         endif
     endif
     !broadcast
     CALL mp_bcast(tau, ionode_id, world_comm)
     CALL mp_bcast(vel, ionode_id, world_comm)
     if (.not. allocated(ion_vel)) then
         allocate(ion_vel,source=vel)
     else
         ion_vel=vel
     endif
     call convert_tau ( tau_format, nat, vel)
     tau=tau + delta_t * vel
     call mp_barrier(world_comm) 
     call update_pot()
     call hinit1()
     ethr = 1.0D-6
end subroutine

function read_next_step(t) result(res)
USE extrapolation,        ONLY : update_pot
USE control_flags,        ONLY : ethr
    use cpv_traj , only : cpv_trajectory, cpv_trajectory_initialize, cpv_trajectory_deallocate, &
                          cpv_trajectory_read_step, cpv_trajectory_get_step
    use traj_object, only : timestep ! type for timestep data
    use kinds, only : dp
use  ions_base,     ONLY :  tau, tau_format, nat
use cell_base, only : alat
use dynamics_module, only : vel
use io_global, ONLY: ionode, ionode_id
USE mp_world,             ONLY : world_comm
use mp, ONLY: mp_bcast, mp_barrier
use zero_mod, only : vel_input_units, ion_vel
    implicit none
    type(cpv_trajectory), intent(inout) :: t
    type(timestep) :: ts
    logical :: res
    integer,save :: step_idx = 0
    if (ionode) then 
        if (cpv_trajectory_read_step(t)) then
            step_idx = step_idx + 1
            call cpv_trajectory_get_step(t,step_idx,ts)
            write (*,*) 'STEP', ts%nstep, ts%tps
            vel=ts%vel
            tau=ts%tau
            CALL convert_tau ( tau_format, nat, tau)
            res=.true.
        else
            write(*,*) 'Finished reading trajectory ', t%fname
            res=.false.
        endif
    endif
    CALL mp_bcast(res, ionode_id, world_comm)
    if (res) then
         CALL mp_bcast(vel, ionode_id, world_comm)
         CALL mp_bcast(tau, ionode_id, world_comm)
         call update_pot()
         call hinit1()
         ethr = 1.0D-6
    end if
    
end function

end program all_currents
