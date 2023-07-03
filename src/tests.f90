program tests
!simulates an object in a windtunnel

    use vars
    use parallel
    use poisson_solver_cuda_mod
    real , dimension(:,:) , allocatable :: psi_backup,u_backup,v_backup,vort_backup
    integer :: rank
    real :: tmp


    call setup_MPI()

    call get_params()

    device = .true.

    call setup()

    call setup_gpu()

    !call solver()

    !call writetofile('output.dat')

    !call getv_cpu()

    !call MPI_Comm_rank ( MPI_COMM_WORLD, rank, ierr )

    !call MPI_Barrier(MPI_COMM_WORLD,ierr)
    !if (rank == 0) print *,"sum_vort", sum( abs(vort) )
    !call MPI_Barrier(MPI_COMM_WORLD,ierr)
    !if (rank == 1) print "(A,' ',F10.7)","sum_vort", sum( v) 

    ! if (device == .true.) psi=psi_dev

    ! print *,sum( psi)




    !call check_vertical_boundary()
    
    !call check_right_boundary()

    !call check_poisson_step()

    !call check_vorticity()

    !call check_velocity()

    !call mpi_finalize(ierr)

    call check_vorticity_evolution()


contains

    subroutine check( message, condition)
        logical, intent(in) :: condition
        character(len=*) :: message
        character(len=40) :: color



        if ( condition) then
            color='\033[32m'
        else
            color='\033[0;31m'
        endif 

        print * , trim(color) //trim(message)  , condition, '\033[0m'

        
    end subroutine


    subroutine check_velocity()
        use vars
        use cuda_kernels
        implicit none
        real , allocatable, dimension(:,:) :: u2,v2

        u=0.
        v=0.

        u_dev=0
        v_dev=0

        psi_dev=psi
        u_dev=u 
        v_dev=v

        allocate( u2(nx,ny),v2(nx,ny) )

        call getv_cpu()
        call getv_gpu()

        u2=u_dev
        v2=v_dev
        
        call check( "Test bulk velocity u", sum(abs(u2 - u))< 1e-5  )
        call check( "Test bulk velocity v", sum(abs(v2 - v))< 1e-5  )

        print *,sum(abs(u2 - u))
    end subroutine
    
    subroutine check_vorticity()
            use vars
            use cuda_kernels
            implicit none 
            real , dimension(0:nx+1,0:ny+1) :: vort2
            real , dimension(0:nx+1,0:ny+1) :: vort_backup
            real :: diff
            


            call getvort_cpu()

            vort_backup=vort
            u_dev=u
            v_dev=v
            vort_dev=vort
            mask_dev=mask


            call navier_stokes_cpu( )

            
            call navier_stokes_gpu()


            vort2=vort_dev

            diff = sum( abs(vort2(1:nx,1:ny) - vort(1:nx,1:ny)) )
            call check( "navier_stokes bulk", diff < 1e-7)
            diff = sum( abs(vort2 - vort ) )
            call check( "navier_stokes", diff < 1e-7)

            !print *,diff

            


    end subroutine

    
    subroutine check_poisson_step()
        implicit none
        real, dimension(:,:) , allocatable :: psi_backup,psi_cpu
        integer :: istat
        real :: diff

        allocate(psi_backup(lbound(psi,1):ubound(psi,1),lbound(psi,2):ubound(psi,2)))
        allocate(psi_cpu(lbound(psi,1):ubound(psi,1),lbound(psi,2):ubound(psi,2)))
        psi_backup=psi
        call poisson_cpu(1)
        psi_cpu=psi


        psi_dev=psi_backup
        mask_dev=mask
        call poisson_gpu(1)
        psi=psi_dev
        call check( "Bulk difference check n=1: " ,  sum( abs( psi_cpu - psi ) )<1e-7 )

        psi=psi_backup

        print *, "running on the cpu..."
        call poisson_cpu(3000)
        psi_cpu=psi


        psi_dev=psi_backup
        print *, "running on the gpu..."
        call poisson_gpu(3000)
        
        istat= cudaDeviceSynchronize()
        psi=psi_dev
        !call check( "Bulk difference check n=5000: " ,  sum( abs( psi_cpu(1:nx,1:ny) - psi(1:nx,1:ny) ) )<1e-1 )

        diff = sum( abs(psi_cpu(1:nx,1:ny) - psi(1:nx,1:ny) ) )/sum(abs(psi_cpu(1:nx,1:ny)))
        
        print *, cudaGetErrorString(cudaGetLastError())
        call check( "Bulk difference check n=3000: " , diff<1e-6 )

        
        print *, diff





    end subroutine

    subroutine check_right_boundary()
        implicit none

        real, dimension( :, :) , allocatable,device :: psi_dev
        real, dimension( :, :) , allocatable :: psi_cpu


        allocate(psi_cpu(0:nx+1,0:ny+1) ,  psi_dev(0:nx+1,0:ny+1) )

        psi_cpu=1
        psi_cpu(nx,1:ny)=0

        psi_dev = psi_cpu

        call fill_right_boundary_gpu(psi_dev)
        psi_cpu=0
        psi_cpu=psi_dev

        call check("Check right boundary", sum( abs(psi_cpu(nx+1,1:ny) - (-1)) ) < 1e-5   )

    end subroutine 
    
    
    subroutine check_vertical_boundary()
        use parallel
        use mpi
        implicit none

        real, dimension( :, :) , allocatable,device :: psi_dev
        real, dimension( :, :) , allocatable :: psi_cpu

        allocate(psi_cpu(0:nx+1,0:ny+1) ,  psi_dev(0:nx+1,0:ny+1) )

        psi_cpu=1
        psi_cpu(:, ny )=0
        psi_cpu(:,1)=0

        psi_dev = psi_cpu

        call fill_vertical_boundary_gpu(psi_dev)
        psi_cpu=0
        psi_cpu=psi_dev

        if (up .eq. MPI_PROC_NULL) call check("Check top boundary",sum( abs(psi_cpu(:,ny+1) - (-1))  ) < 1e-5 )
        if (down .eq. MPI_PROC_NULL ) call check("Check bottom boundary",sum( abs( psi_cpu(:,0) - (-1)) ) < 1e-5 )


    end subroutine  




subroutine check_vorticity_evolution()
!determines the flow profile around the object. In order to do this we have to solve 2
!coupled equations:
! - calculate the streamfunction (psi) by solving Poisson's equation
! - update the vorticity by solving the vorticity transport equation (from the NS equations)
!
!First of all a potential flow is calculated around the object (solving Laplace's equation)
!then (optionally) the vorticity is turned on and alternately Poisson's equation and the
!vorticity transport equation are iterated to determine the fluid flow.

    use vars
    use parallel
    use cuda_kernels
    use cudafor
    use mpi

    implicit none

    real :: time
    double precision :: tstart=0, tstop=0,sum_psi_cpu=0
    integer:: i,iErr
    real, dimension( :, :) , allocatable :: psi_backup
    real , dimension(0:nx+1,0:ny+1) :: vort_backup
    real , dimension(1:nx,1:ny) :: u_backup
    real , dimension(1:nx,1:ny) :: v_backup




    allocate( psi_backup(0:nx+1,0:ny+1) )

    !$OMP PARALLEL
    !solve Laplace's equation for the irrotational flow profile (vorticity=0)
    call poisson_cpu(5000)
    !$OMP END PARALLEL



    !get the vorticity on the surface of the object
    ! ierr=cudaDeviceSynchronize()
    call getvort_cpu()



    time=0.
    u=0.
    v=0.

    psi_dev=psi
    vort_dev=vort
    v_dev=v 
    u_dev=u
    dw=0
    dw_dev=dw
    
    do i = 1, 20
              !if (irank .eq. 0) print*, "t=",time,"of",nx*crossing_times
            

            call getv_cpu() !get the velocity
    ! !         ierr=cudaDeviceSynchronize()

            call navier_stokes_cpu() !solve dw/dt=f(w,psi) for a timestep
    ! !         ierr=cudaDeviceSynchronize()

            call poisson_cpu(2) !2 poisson 'relaxation' steps
    ! !         ierr=cudaDeviceSynchronize()

            call getv_gpu()
            call navier_stokes_gpu()
            call poisson_gpu(2) 
            
            call MPI_Barrier(MPI_COMM_WORLD,ierr)

            sum_psi_cpu=sum(psi(0:nx+1,0:ny+1))
            psi_backup=psi_dev
            vort_backup=vort_dev
            v_backup=v_dev 
            u_backup=u_dev

            print * ,"psi_sum",(sum_psi_cpu - sum(psi_backup(0:nx+1,0:ny+1) ) )
            print * ,"vort",irank,sum( abs(vort(0:nx+1,0:ny+1) ) - abs(vort_backup(0:nx+1,0:ny+1) ) )
            print * ,"u",irank,sum( abs(u_backup(1:nx,1:ny)) ) - sum( abs(u(1:nx,1:ny)) ) 
            print * ,"v",irank,sum( abs(v_backup(1:nx,1:ny)) ) - sum( abs(v(1:nx,1:ny) ))

            time=time+dt
    enddo



end subroutine

    





end program
